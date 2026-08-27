defmodule BatataTest do
  use ExUnit.Case, async: true

  alias Beaver.MLIR

  test "compiles source into verified ex IR" do
    ctx = MLIR.Context.create()

    try do
      module =
        Batata.compile(
          """
          defmodule Math do
            def main() do
              1 + 2
            end
          end
          """,
          ctx
        )

      assert MLIR.verify?(module)
      assert MLIR.to_string(module, generic: true) =~ ~s{"ex.func"}
      assert MLIR.to_string(module, generic: true) =~ ~s{"ex.add"}
    after
      MLIR.Context.destroy(ctx)
    end
  end

  test "profiles frontend-to-Ex compilation with bounded stages" do
    ctx = MLIR.Context.create()

    try do
      assert {{:ok, module}, receipt} =
               Batata.profile_compile(
                 """
                 defmodule ProfiledMath do
                   def main(), do: add(1, 2)
                   def add(left, right), do: left + right
                 end
                 """,
                 ctx
               )

      assert receipt["schema_version"] == 1
      assert receipt["pipeline"] == "frontend_to_ex"
      assert receipt["status"] == "ok"

      assert Enum.map(receipt["stages"], & &1["name"]) ==
               ~w(snapshot lift inline_scalar_calls expand_case verify memory_verify)

      assert Enum.all?(receipt["stages"], &(&1["status"] == "ok"))
      assert is_binary(JSON.encode!(receipt))

      module
      |> MLIR.Operation.from_module()
      |> MLIR.CAPI.beaverOperationDestroyIterative_dirty_cpu()
    after
      MLIR.Context.destroy(ctx)
    end
  end

  test "retains the failed compile stage" do
    ctx = MLIR.Context.create()

    try do
      assert {{:error, :error, %ArgumentError{}, stacktrace}, receipt} =
               Batata.profile_compile("defmodule Invalid do end", ctx, reduction_budget: 0)

      assert is_list(stacktrace)
      assert receipt["status"] == "error"
      assert [%{"name" => "snapshot", "status" => "error"}] = receipt["stages"]
      assert is_binary(JSON.encode!(receipt))
    after
      MLIR.Context.destroy(ctx)
    end
  end
end
