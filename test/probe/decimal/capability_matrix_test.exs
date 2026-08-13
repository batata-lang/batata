defmodule Batata.Probe.Decimal.CapabilityMatrixTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CapabilityMatrix

  test "marks aggregate numeric guards executable only with both sub-capabilities" do
    matrix = CapabilityMatrix.load!("probe/decimal/capabilities.json")
    capabilities = Map.new(matrix["capabilities"], &{&1["id"], &1})

    assert capabilities["decimal.comparison_guards"]["status"] == "executable"
    assert capabilities["decimal.comparison_guards"]["gate"] == "decimal_subset_test"
    assert capabilities["decimal.guard_bifs"]["status"] == "executable"
    assert capabilities["decimal.guard_bifs"]["gate"] == "decimal_subset_test"
    assert capabilities["decimal.numeric_guards"]["status"] == "executable"
    assert capabilities["decimal.numeric_guards"]["gate"] == "decimal_subset_test"
    assert capabilities["decimal.normalization"]["status"] == "executable"
    assert capabilities["decimal.normalization"]["gate"] == "decimal_subset_test"
  end
end
