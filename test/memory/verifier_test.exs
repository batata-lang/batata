defmodule Batata.Memory.VerifierTest do
  use Batata.Case, async: true

  alias Batata.Memory
  alias Batata.Memory.{Bound, DiagnosticError, Plan, Receipt}

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
    assert Enum.any?(plan.effects, &(&1.classification == :exact))
    assert Enum.any?(plan.obligations, &(&1.kind == :allocation_precondition_missing))
    refute Enum.any?(plan.obligations, &(&1.kind == :callee_summary_missing))
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

  test "runtime quota closes dynamic sites while constructors retain exact layouts", %{ctx: ctx} do
    source = """
    defmodule ClosedMemory do
      def main(), do: {{1, 2}, [3, 4], %{answer: 42}, <<1, 2, 3>>}
    end
    """

    plan =
      source
      |> Batata.compile(ctx)
      |> Memory.analyze(
        module: ClosedMemory,
        source: source,
        policy: :strict,
        quota_bytes: 67_108_864
      )

    assert plan.obligations == []
    assert {:ok, 67_108_864} = Bound.evaluate(plan.maximum_memory)
    assert Enum.any?(plan.effects, &(&1.classification == :guarded))

    exact_operations =
      plan.effects
      |> Enum.filter(&(&1.classification == :exact))
      |> Enum.map(& &1.context["operation"])

    assert "ex.tuple" in exact_operations
    assert "ex.list" in exact_operations
    assert "ex.map" in exact_operations
    assert "ex.binary" in exact_operations

    assert Enum.all?(Enum.filter(plan.effects, &(&1.classification == :exact)), fn effect ->
             effect.escape == :result and effect.lifetime["scope"] == "pinned-execution" and
               effect.context["lifetime_strategy"]["id"] == "pin-execution-arena" and
               effect.context["value_ids"] != []
           end)

    receipt = Receipt.from_plan!(plan)
    assert receipt.maximum_memory == "67108864"
    assert Receipt.verify(receipt, plan) == :ok

    assert Enum.any?(plan.regions, fn region ->
             region.kind == :execution and
               region.physical_backend == "segmented-bump-execution-arena" and
               region.reset["verified"]
           end)

    assert [%{"verified" => true, "site_id" => reset_site}] = plan.reset_points
    assert String.starts_with?(reset_site, "mem://")
  end

  test "recursive allocation requires and consumes a finite iteration contract", %{ctx: ctx} do
    source = """
    defmodule RecursiveMemory do
      def build(), do: [1 | build()]
      def main(), do: build()
    end
    """

    module = Batata.compile(source, ctx)

    open_plan =
      Memory.analyze(module,
        module: RecursiveMemory,
        source: source,
        policy: :report,
        quota_bytes: 67_108_864
      )

    recursion = Enum.find(open_plan.obligations, &(&1.kind == :recursion_bound_missing))
    assert recursion

    variable = recursion.strategies |> hd() |> Map.fetch!("variable")

    closed_plan =
      Memory.analyze(module,
        module: RecursiveMemory,
        source: source,
        policy: :strict,
        quota_bytes: 67_108_864,
        contracts: %{variable => 4}
      )

    assert closed_plan.obligations == []

    assert Enum.any?(closed_plan.effects, fn effect ->
             effect.classification == :parametric and variable in Bound.variables(effect.size)
           end)
  end

  test "message payloads select the quiescence-checked execution-arena strategy", %{ctx: ctx} do
    source = """
    defmodule MessageMemory do
      def main() do
        pid = self()
        send(pid, {1, 2})
      end
    end
    """

    plan =
      source
      |> Batata.compile(ctx)
      |> Memory.analyze(
        module: MessageMemory,
        source: source,
        policy: :report,
        quota_bytes: 67_108_864
      )

    tuple = Enum.find(plan.effects, &(&1.context["operation"] == "ex.tuple"))

    assert tuple.escape == :process_send
    assert tuple.lifetime == %{"end" => "execution-quiescence", "scope" => "actor-message"}
    assert tuple.context["lifetime_strategy"]["id"] == "retain-in-execution-arena"

    assert Enum.any?(plan.regions, fn region ->
             region.kind == :actor and "cross-actor-retention" in region.capabilities and
               region.physical_backend == "segmented-bump-execution-arena"
           end)
  end
end
