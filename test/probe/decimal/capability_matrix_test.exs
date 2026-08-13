defmodule Batata.Probe.Decimal.CapabilityMatrixTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CapabilityMatrix

  test "keeps aggregate numeric guards blocked until every sub-capability executes" do
    matrix = CapabilityMatrix.load!("probe/decimal/capabilities.json")
    capabilities = Map.new(matrix["capabilities"], &{&1["id"], &1})

    assert capabilities["decimal.comparison_guards"]["status"] == "executable"
    assert capabilities["decimal.comparison_guards"]["gate"] == "decimal_subset_test"
    assert capabilities["decimal.guard_bifs"]["status"] == "blocked"
    assert capabilities["decimal.numeric_guards"]["status"] == "blocked"
  end
end
