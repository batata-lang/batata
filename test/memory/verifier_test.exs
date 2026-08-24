defmodule Batata.Memory.VerifierTest do
  use Batata.Case, async: true

  alias Batata.Memory
  alias Batata.Memory.{DiagnosticError, Plan}

  @source """
  defmodule MemorySample do
    def pair(), do: {1, 2}
    def main(), do: is_tuple(pair())
  end
  """

  test "report mode inventories allocation and residual obligations", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    plan =
      Memory.analyze(module,
        module: MemorySample,
        source: @source,
        policy: :report
      )

    assert %Plan{policy: :report} = plan
    assert plan.compiler_version == "0.1.0"
    assert String.starts_with?(plan.dependency_lock, "sha256:")
    assert Enum.any?(plan.effects, &(&1.classification == :may_allocate))
    assert Enum.any?(plan.obligations, &(&1.kind == :allocation_bound_missing))
    assert Enum.any?(plan.obligations, &(&1.kind == :callee_summary_missing))
    refute Enum.any?(plan.obligations, &(&1.kind == :external_summary_missing))
  end

  test "structurally identical operations are grouped without traversal ordinals", %{ctx: ctx} do
    source = """
    defmodule RepeatedSites do
      def main(), do: {{1}, {1}}
    end
    """

    plan =
      source
      |> Batata.compile(ctx)
      |> Memory.analyze(
        module: RepeatedSites,
        source: source,
        policy: :report,
        dependency_lock: "sha256:test-lock"
      )

    assert Enum.any?(plan.effects, fn effect ->
             effect.context["multiplicity"] > 1 and effect.context["operation"] == "ex.lit"
           end)

    assert Enum.all?(plan.effects, fn effect ->
             effect.site.semantic_path |> Enum.join("/") |> String.contains?("equivalence")
           end)
  end

  test "strict mode raises a canonical diagnostic before lowering", %{ctx: ctx} do
    error =
      assert_raise DiagnosticError, fn ->
        Batata.compile(@source, ctx,
          memory_policy: :strict,
          memory_dependency_lock: "sha256:test-lock"
        )
      end

    decoded = error |> Exception.message() |> JSON.decode!()
    assert String.starts_with?(decoded["code"], "E_MEMORY_")
    assert decoded["policy"] == "strict"
    assert decoded["obstruction"]["missing_fact"]
  end

  test "policy defaults disabled and rejects misspellings", %{ctx: ctx} do
    assert %Beaver.MLIR.Module{} = Batata.compile(@source, ctx)
    assert %Beaver.MLIR.Module{} = Batata.compile(@source, ctx, memory_policy: :report)

    assert_raise ArgumentError, ~r/memory_policy must be/, fn ->
      Batata.compile(@source, ctx, memory_policy: :warn)
    end
  end
end
