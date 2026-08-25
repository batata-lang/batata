defmodule Batata.Memory.SchemaTest do
  use ExUnit.Case, async: true

  alias Batata.Memory

  alias Batata.Memory.{
    Bound,
    DiagnosticError,
    Effect,
    Obligation,
    Plan,
    Receipt,
    Region,
    Repair,
    Site,
    Strategy
  }

  test "symbolic bounds normalize and evaluate deterministically" do
    bound =
      Bound.add([
        Bound.constant(8),
        Bound.multiply([Bound.variable("input:items"), Bound.constant(16)]),
        Bound.constant(8)
      ])

    assert Bound.variables(bound) == ["input:items"]
    assert Bound.evaluate(bound, %{"input:items" => 3}) == {:ok, 64}
    assert Bound.evaluate(bound) == {:error, ["input:items"]}

    assert Bound.canonical_map(bound) == %{
             "op" => "sum",
             "terms" => [
               %{"bytes" => "16", "op" => "constant"},
               %{
                 "op" => "product",
                 "terms" => [
                   %{"bytes" => "16", "op" => "constant"},
                   %{"name" => "input:items", "op" => "variable"}
                 ]
               }
             ]
           }
  end

  test "canonical JSON sorts keys and rejects ambiguous scalar domains" do
    assert Memory.canonical_json(%{"a" => %{a: nil, b: true}, z: [2, 1]}) ==
             ~s({"a":{"a":null,"b":true},"z":[2,1]})

    assert_raise ArgumentError, ~r/duplicate canonical memory JSON key/, fn ->
      Memory.canonical_json(%{"same" => 2, same: 1})
    end

    assert_raise ArgumentError, ~r/supports only/, fn -> Memory.canonical_json(1.5) end
  end

  test "structural site identity ignores display-only locations" do
    opts = [
      module: Decoder,
      function: :decode,
      arity: 1,
      semantic_path: [:body, :call, "Native.decode/1"],
      identity: %{"callee" => "Native.decode/1", "kind" => "call"}
    ]

    structural = Site.structural!(opts)
    located = Site.structural!(opts ++ [source_span: "lib/decoder.ex:48:9", provenance: :source])

    assert structural.id == located.id
    assert structural.structural_digest == located.structural_digest
    assert structural.source_span == nil
    assert structural.provenance == :structural
    assert located.source_span == "lib/decoder.ex:48:9"
    assert String.starts_with?(structural.id, "mem://Elixir.Decoder/decode/1/site/sha256:")
  end

  test "plan ordering and digest are independent of analysis discovery order" do
    first = site(:first)
    second = site(:second)
    first_effect = effect(first, :none)
    second_effect = effect(second, :unknown)
    first_obligation = obligation(first, :external_summary_missing)
    second_obligation = obligation(second, :allocation_effect_unknown)

    left =
      plan(
        effects: [second_effect, first_effect],
        obligations: [second_obligation, first_obligation]
      )

    right =
      plan(
        effects: [first_effect, second_effect],
        obligations: [first_obligation, second_obligation]
      )

    assert Plan.canonical_json(left) == Plan.canonical_json(right)
    assert Plan.digest(left) == Plan.digest(right)
  end

  test "diagnostic is a stable JSON exception with repair hints" do
    site = site(:external)
    obstruction = obligation(site, :external_summary_missing)

    diagnostic =
      DiagnosticError.exception(
        code: "E_MEMORY_EFFECT_UNKNOWN",
        message: "external call has no allocation summary",
        policy: :strict,
        site: site,
        obstruction: obstruction,
        strategies: [%{"id" => "declare-summary", "requires" => ["closed provider plan"]}]
      )

    decoded = diagnostic |> Exception.message() |> JSON.decode!()

    assert decoded["schema"] == "batata-memory/1"
    assert decoded["code"] == "E_MEMORY_EFFECT_UNKNOWN"
    assert decoded["site"]["id"] == site.id
    assert decoded["recoverable"]
  end

  test "bounded receipt rejects residual obligations and non-canonical bounds" do
    fields = [
      source_hash: hash("source"),
      compiler_version: "0.1.0",
      dependency_lock: hash("lock"),
      memory_plan_hash: hash("plan"),
      maximum_memory: "16777216"
    ]

    receipt = Receipt.new!(fields)
    assert JSON.decode!(Receipt.canonical_json(receipt))["assurance"] == "bounded"

    assert_raise ArgumentError, ~r/zero unproven obligations/, fn ->
      Receipt.new!(fields ++ [unproven_obligations: [%{"kind" => "unknown"}]])
    end

    assert_raise ArgumentError, ~r/non-negative integer string/, fn ->
      Receipt.new!(Keyword.put(fields, :maximum_memory, "016"))
    end
  end

  test "receipt verifies against a closed plan without compiler process state" do
    plan =
      plan(
        maximum_memory: Bound.add([Bound.constant(16), Bound.variable("input:bytes")]),
        preconditions: [%{"maximum_bytes" => "48", "variable" => "input:bytes"}]
      )

    contracts = %{"input:bytes" => 48}
    receipt = Receipt.from_plan!(plan, contracts)

    assert receipt.maximum_memory == "64"
    assert Receipt.verify(receipt, plan, contracts) == :ok

    assert Receipt.verify(receipt, %{plan | source_hash: hash("different")}, contracts) ==
             {:error, :receipt_mismatch}
  end

  test "runtime limits are bound into plan and receipt hashes" do
    limit = %{
      "effective_bytes" => "4096",
      "enforcement" => "native-runtime",
      "hard_limit_bytes" => "67108864",
      "id" => "execution-arena",
      "scope" => "per-runtime-execution"
    }

    plan = plan(maximum_memory: Bound.constant(64), runtime_limits: [limit])
    receipt = Receipt.from_plan!(plan)

    assert JSON.decode!(Plan.canonical_json(plan))["schema"] == "batata-memory-plan/4"
    assert JSON.decode!(Receipt.canonical_json(receipt))["schema"] == "batata-memory-receipt/2"
    assert receipt.runtime_limits == [limit]
    assert Receipt.verify(receipt, plan) == :ok

    changed = put_in(limit["effective_bytes"], "8192")

    assert Receipt.verify(receipt, %{plan | runtime_limits: [changed]}) ==
             {:error, :receipt_mismatch}
  end

  test "reset verification fails closed on missing or reordered lifecycle operations" do
    assert Region.verify_reset_sequence([
             "ex.runtime_enter",
             "ex.process_table_reset",
             "ex.result_create",
             "ex.runtime_leave"
           ]) == :ok

    assert {:error, _reason} =
             Region.verify_reset_sequence([
               "ex.runtime_enter",
               "ex.result_create",
               "ex.process_table_reset",
               "ex.runtime_leave"
             ])
  end

  test "repair requests expose catalog strategies but require a full recomputation" do
    site = site(:dynamic)

    obligation =
      Obligation.new!(
        kind: :allocation_precondition_missing,
        site: site,
        missing_fact: "dynamic allocation bound",
        strategies: [
          %{"action" => "set-memory-contract", "variable" => "allocation-bytes:test"}
        ]
      )

    open_plan = plan(obligations: [obligation])
    request = Repair.canonical_map(open_plan)

    assert request["full_recompute_required"]

    assert get_in(request, ["obstructions", Access.at(0), "candidates", Access.at(0), "id"]) ==
             "set-memory-contract"

    assert Enum.any?(Strategy.catalog(), fn strategy ->
             strategy["id"] == "use-refcounted-large-binary" and not strategy["available"]
           end)

    assert Repair.verify_recomputed(open_plan, open_plan, receipt_for(open_plan)) ==
             {:error, :residual_obligations}
  end

  defp site(name) do
    Site.structural!(
      module: Sample,
      function: :main,
      arity: 0,
      semantic_path: [:body, name],
      identity: %{"kind" => Atom.to_string(name)}
    )
  end

  defp effect(site, classification) do
    Effect.new!(site: site, classification: classification, provenance: :test)
  end

  defp obligation(site, kind) do
    Obligation.new!(kind: kind, site: site, missing_fact: "test fact")
  end

  defp plan(opts) do
    Plan.new!(
      [
        policy: :report,
        source_hash: hash("source"),
        compiler_version: "0.1.0",
        dependency_lock: hash("lock")
      ] ++ opts
    )
  end

  defp receipt_for(plan) do
    Receipt.new!(
      source_hash: plan.source_hash,
      compiler_version: plan.compiler_version,
      dependency_lock: plan.dependency_lock,
      memory_plan_hash: "sha256:" <> Plan.digest(plan),
      maximum_memory: "0"
    )
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
