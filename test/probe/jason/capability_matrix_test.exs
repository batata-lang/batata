defmodule Batata.Probe.Jason.CapabilityMatrixTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CapabilityMatrix

  test "tracks executable semantics separately from source inventory counts" do
    matrix = CapabilityMatrix.load!("probe/jason/capabilities.json")
    capabilities = Map.new(matrix["capabilities"], &{&1["id"], &1})

    assert capabilities["container.recursive"]["status"] == "executable"
    assert capabilities["parser.cursor_value"]["status"] == "executable"
    assert capabilities["container.dynamic_map"]["status"] == "executable"
    assert capabilities["string.dynamic_binary"]["status"] == "executable"
    assert capabilities["jason.unmodified"]["owner"] == "frontend"
    assert capabilities["fixture.second"]["status"] == "blocked"
  end

  test "pins JSONTestSuite as data corpus rather than implementation fixture" do
    source = "probe/json_test_suite/source.json" |> File.read!() |> JSON.decode!()

    assert source["commit"] =~ ~r/^[0-9a-f]{40}$/
    assert source["role"] =~ "input/output corpus"
  end
end
