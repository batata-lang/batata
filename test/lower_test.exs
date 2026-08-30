defmodule Batata.LowerTest do
  use Batata.Case, async: true

  alias Batata
  alias Batata.Lower

  test "lowers the scalar slice from ex IR to func/arith and LLVM", %{ctx: ctx} do
    module =
      Batata.to_llvm(
        """
        defmodule Math do
          def main() do
            a = 1 + 2
            a + 3
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module)
    refute rendered =~ "\"ex."
    assert rendered =~ "llvm.func"
    assert rendered =~ "llvm.add"
  end

  test "lowers a non-scalar local call into a func.call", %{ctx: ctx} do
    module =
      Batata.to_llvm(
        """
        defmodule Math do
          def main() do
            helper()
          end

          def helper() do
            {1, 2}
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module)
    refute rendered =~ ~s{"ex.}
    assert rendered =~ "llvm.func"
  end

  test "rejects an invalid conversion provider before mutating the module", %{ctx: ctx} do
    module =
      Batata.compile(
        """
        defmodule InvalidProvider do
          def main(), do: 1 + 2
        end
        """,
        ctx
      )

    before = MLIR.to_string(module, generic: true)

    assert_raise ArgumentError, ~r/:conversion_plan must be a conversion plan/, fn ->
      Lower.to_func(module, conversion_plan: :implicit_fallback)
    end

    assert MLIR.to_string(module, generic: true) == before
  end

  test "injects the physical arena quota at the Lower boundary", %{ctx: ctx} do
    module =
      Batata.compile(
        """
        defmodule Quota do
          def main(), do: [1, 2]
        end
        """,
        ctx,
        memory_quota_bytes: 4_096
      )

    rendered =
      module
      |> Batata.Lower.to_func(memory_quota_bytes: 4_096)
      |> MLIR.to_string()

    assert rendered =~ "call @ex.term.runtime_set_arena_limit"
    assert rendered =~ "arith.constant 4096 : i64"
    assert rendered =~ "func.func private @ex.term.runtime_set_arena_limit(i64, i64) -> i64"

    assert index(rendered, "ex.term.runtime_create") <
             index(rendered, "ex.term.runtime_set_arena_limit")

    assert index(rendered, "ex.term.runtime_set_arena_limit") <
             index(rendered, "ex.term.runtime_enter")
  end

  test "returns bounded native action summaries for ex conversion", %{ctx: ctx} do
    module =
      Batata.compile(
        """
        defmodule TracedTuple do
          def main(), do: {1, 2}
        end
        """,
        ctx
      )

    {module, receipt} = Lower.to_func_with_trace(module)

    assert receipt["schema_version"] == 1
    assert receipt["pipeline"] == "ex_to_func"
    assert receipt["duration_ns"] >= 0
    assert receipt["status"] == "ok"

    assert [
             %{
               "name" => "ex_conversion",
               "actions" => actions,
               "conversion_profile" => conversion_profile
             }
           ] = receipt["stages"]

    assert conversion_profile["status"] == "ok"
    assert conversion_profile["beam"]["callback_count"] > 0
    refute Enum.any?(conversion_profile["callbacks"], &(&1["kind"] == "convert_type"))

    assert Enum.any?(actions, fn action ->
             action["tag"] == "apply-conversion" and action["count"] == 1 and
               action["duration_ns"] >= 0
           end)

    assert Enum.any?(actions, fn action ->
             action["tag"] == "apply-pattern" and action["operation"] == "ex.tuple" and
               action["count"] >= 1
           end)

    refute MLIR.to_string(module) =~ ~s{"ex.}
    assert is_binary(JSON.encode!(receipt))
  end

  test "separates every native lowering pass in the trace receipt", %{ctx: ctx} do
    module =
      Batata.compile(
        """
        defmodule TracedMath do
          def main(), do: 1 + 2
        end
        """,
        ctx
      )

    {module, receipt} = Lower.to_llvm_with_trace(module, ctx)
    stages = receipt["stages"]

    assert Enum.map(stages, & &1["name"]) == [
             "ex_conversion",
             "arith_to_llvm",
             "scf_to_cf",
             "cf_to_llvm",
             "func_to_llvm"
           ]

    for stage <- Enum.drop(stages, 1) do
      assert [pass] = Enum.filter(stage["actions"], &(&1["tag"] == "pass-execution"))
      assert pass["count"] == 1
      assert pass["description"] =~ "Pass`"
    end

    assert MLIR.to_string(module) =~ "llvm.func"
  end

  test "retains completed and failed stages when profiled lowering fails", %{ctx: ctx} do
    module =
      Batata.compile(
        """
        defmodule ProfileFailure do
          def main(value), do: missing(value)
        end
        """,
        ctx
      )

    assert {{:error, :error, %Lower.Error{}, stacktrace}, receipt} =
             Lower.profile_to_llvm(module, ctx)

    assert is_list(stacktrace)
    assert receipt["status"] == "error"
    assert hd(receipt["stages"])["conversion_profile"]["status"] == "ok"

    assert %{"name" => failed_stage, "status" => "error"} = List.last(receipt["stages"])
    assert failed_stage in ~w(arith_to_llvm scf_to_cf cf_to_llvm func_to_llvm)

    assert is_binary(JSON.encode!(receipt))
  end

  defp index(text, pattern) do
    {offset, _length} = :binary.match(text, pattern)
    offset
  end
end
