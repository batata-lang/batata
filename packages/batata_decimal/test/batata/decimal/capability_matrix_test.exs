defmodule Batata.Probe.Decimal.CapabilityMatrixTest do
  use ExUnit.Case, async: true

  alias Batata.Decimal.Probe
  alias Batata.Probe.CapabilityMatrix

  test "marks aggregate numeric guards executable only with both sub-capabilities" do
    matrix = CapabilityMatrix.load!(Probe.asset!("capabilities.json"))
    capabilities = Map.new(matrix["capabilities"], &{&1["id"], &1})

    assert capabilities["pattern.map_subset"]["gate"] == "execute_test"
    assert capabilities["pattern.map_parameter"]["status"] == "executable"
    assert capabilities["pattern.struct"]["status"] == "executable"
    assert capabilities["pattern.struct"]["gate"] == "execute_test"
    assert capabilities["map.update_exact"]["status"] == "executable"
    assert capabilities["map.update_exact"]["gate"] == "execute_test"
    assert capabilities["dispatch.non_exhaustive"]["status"] == "executable"
    assert capabilities["string.interpolation"]["status"] == "executable"
    assert capabilities["string.interpolation"]["gate"] == "execute_test"
    assert capabilities["string.interpolation"]["scope"] =~ "compile-known atom"
    assert capabilities["string.concat"]["status"] == "executable"
    assert capabilities["string.concat"]["gate"] == "execute_test"
    assert capabilities["string.concat"]["scope"] == "binary operands"
    assert capabilities["control.short_circuit_and"]["status"] == "executable"
    assert capabilities["control.short_circuit_and"]["gate"] == "execute_test"

    assert capabilities["control.short_circuit_and"]["scope"] =~
             "right-hand-side assignments excluded"

    assert capabilities["control.if"]["status"] == "executable"
    assert capabilities["control.if"]["gate"] == "execute_test"
    assert capabilities["control.if"]["scope"] =~ "missing else yields nil"
    assert capabilities["control.if"]["scope"] =~ "branch assignments excluded"
    assert capabilities["guard.is_function"]["status"] == "executable"
    assert capabilities["guard.is_function"]["gate"] == "execute_test"
    assert capabilities["guard.is_function"]["scope"] =~ "module-local"

    assert capabilities["struct.constructor"]["status"] == "executable"
    assert capabilities["struct.constructor"]["gate"] == "execute_test"
    assert capabilities["exception.schema_compile"]["status"] == "executable"
    assert capabilities["exception.schema_compile"]["gate"] == "compile_probe"
    assert capabilities["exception.execution"]["status"] == "executable"
    assert capabilities["exception.execution"]["gate"] == "unmodified_execution"
    assert capabilities["exception.execution"]["scope"] =~ "Decimal.Error"
    assert capabilities["struct.schema_compile"]["status"] == "executable"
    assert capabilities["struct.schema_compile"]["gate"] == "compile_probe"
    assert capabilities["struct.schema_compile"]["scope"] =~ "current-module defstruct"
    assert capabilities["decimal.struct_surface"]["status"] == "executable"
    assert capabilities["decimal.struct_surface"]["gate"] == "unmodified_execution"

    assert capabilities["decimal.comparison_guards"]["status"] == "executable"
    assert capabilities["decimal.comparison_guards"]["gate"] == "decimal_subset_test"
    assert capabilities["decimal.guard_bifs"]["status"] == "executable"
    assert capabilities["decimal.guard_bifs"]["gate"] == "decimal_subset_test"
    assert capabilities["decimal.numeric_guards"]["status"] == "executable"
    assert capabilities["decimal.numeric_guards"]["gate"] == "decimal_subset_test"
    assert capabilities["decimal.normalization"]["status"] == "executable"
    assert capabilities["decimal.normalization"]["gate"] == "decimal_subset_test"
    assert capabilities["decimal.unmodified_finite"]["status"] == "executable"
    assert capabilities["decimal.unmodified_finite"]["gate"] == "unmodified_execution"
    assert capabilities["decimal.unmodified_finite"]["scope"] =~ "16 BEAM-oracle cases"
  end
end
