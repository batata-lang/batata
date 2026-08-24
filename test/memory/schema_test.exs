defmodule Batata.Memory.SchemaTest do
  use ExUnit.Case, async: true

  alias Batata.Memory
  alias Batata.Memory.{DiagnosticError, Effect, Obligation, Plan, Receipt, Site}

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

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
