defmodule Batata.Probe.Jason.CapabilityMatrixTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CapabilityMatrix

  test "tracks executable semantics separately from source inventory counts" do
    matrix = CapabilityMatrix.load!("probe/jason/capabilities.json")
    capabilities = Map.new(matrix["capabilities"], &{&1["id"], &1})

    assert capabilities["container.recursive"]["status"] == "executable"
    assert capabilities["parser.cursor_value"]["status"] == "executable"
    assert capabilities["container.dynamic_map"]["status"] == "executable"
    assert capabilities["pattern.map_subset"]["gate"] == "execute_test"
    assert capabilities["pattern.map_parameter"]["status"] == "executable"
    assert capabilities["pattern.trailing_map"]["gate"] == "trailing_map_pattern_test"
    assert capabilities["pattern.trailing_map"]["scope"] =~ "atom-key subset maps"
    assert capabilities["pattern.struct"]["status"] == "executable"
    assert capabilities["pattern.struct"]["scope"] =~ "exact __struct__ matching"
    assert capabilities["pattern.dynamic_struct"]["gate"] == "dynamic_struct_module_pattern_test"
    assert capabilities["pattern.dynamic_struct"]["scope"] =~ "bound module variable"
    assert capabilities["map.update_exact"]["status"] == "executable"
    assert capabilities["map.update_exact"]["scope"] =~ "typed KeyError"
    assert capabilities["dispatch.non_exhaustive"]["status"] == "executable"
    assert capabilities["string.dynamic_binary"]["status"] == "executable"

    assert capabilities["string.dynamic_utf8_construction"]["status"] == "executable"
    assert capabilities["string.dynamic_utf8_construction"]["gate"] == "execute_test"

    assert capabilities["string.dynamic_utf8_construction"]["scope"] =~
             "invalid-codepoint raises"

    assert capabilities["string.interpolation"]["status"] == "executable"
    assert capabilities["string.interpolation"]["gate"] == "execute_test"
    assert capabilities["string.interpolation"]["scope"] =~ "compile-known atom"
    assert capabilities["string.concat"]["status"] == "executable"
    assert capabilities["string.concat"]["gate"] == "execute_test"
    assert capabilities["string.concat"]["scope"] == "binary operands"
    assert capabilities["string.printable"]["status"] == "executable"
    assert capabilities["string.printable"]["gate"] == "stdlib_test"
    assert capabilities["string.printable"]["scope"] =~ "FunctionClauseError"
    assert capabilities["kernel.inspect"]["status"] == "executable"
    assert capabilities["kernel.inspect"]["gate"] == "stdlib_test"
    assert capabilities["kernel.inspect"]["scope"] =~ "base: :hex"
    assert capabilities["stdlib.lists_lookup_reverse"]["status"] == "executable"
    assert capabilities["stdlib.lists_lookup_reverse"]["gate"] == "execute_test"
    assert capabilities["stdlib.lists_lookup_reverse"]["scope"] =~ ":lists.keyfind/3"
    assert capabilities["stdlib.enum_term_callbacks"]["status"] == "executable"
    assert capabilities["stdlib.enum_term_callbacks"]["gate"] == "codegen_pattern_mapper_test"
    assert capabilities["stdlib.enum_term_callbacks"]["scope"] =~ "up to four tagged captures"
    assert capabilities["stdlib.list_flatten"]["status"] == "executable"
    assert capabilities["stdlib.list_flatten"]["gate"] == "codegen_pattern_mapper_test"
    assert capabilities["stdlib.list_flatten"]["scope"] =~ "proper nested lists"
    assert capabilities["pattern.multi_head_cons"]["status"] == "executable"
    assert capabilities["pattern.multi_head_cons"]["gate"] == "codegen_pattern_mapper_test"
    assert capabilities["pattern.multi_head_cons"]["scope"] =~ "collapse_static/1"
    assert capabilities["pattern.binary_uint16"]["gate"] == "uint16_binary_pattern_test"
    assert capabilities["pattern.binary_uint16"]["scope"] =~ "unsigned big-endian"
    assert capabilities["pattern.literal_binary_prefix"]["status"] == "executable"
    assert capabilities["pattern.literal_binary_prefix"]["gate"] == "execute_test"
    assert capabilities["pattern.literal_binary_prefix"]["scope"] =~ "trailing binary/bits"
    assert capabilities["control.short_circuit_and"]["status"] == "executable"
    assert capabilities["control.short_circuit_and"]["gate"] == "execute_test"

    assert capabilities["control.short_circuit_and"]["scope"] =~
             "right-hand-side assignments excluded"

    assert capabilities["control.if"]["status"] == "executable"
    assert capabilities["control.if"]["gate"] == "execute_test"
    assert capabilities["control.if"]["scope"] =~ "missing else yields nil"

    assert capabilities["control.if"]["scope"] =~
             "environment-bearing branch assignments excluded"

    assert capabilities["control.if_unused_alias"]["gate"] == "unused_branch_alias_test"
    assert capabilities["control.if_unused_alias"]["scope"] =~ "proven unread"

    assert capabilities["call.scalar_result_inference"]["status"] == "executable"

    assert capabilities["call.scalar_result_inference"]["gate"] ==
             "scalar_result_inference_test"

    assert capabilities["call.scalar_result_inference"]["scope"] =~ "recursive-uncertain"

    assert capabilities["struct.constructor"]["status"] == "executable"
    assert capabilities["struct.constructor"]["gate"] == "execute_test"
    assert capabilities["struct.constructor"]["scope"] =~ "current-module schemas"

    assert capabilities["exception.schema_compile"]["status"] == "executable"
    assert capabilities["exception.schema_compile"]["gate"] == "compile_probe"
    assert capabilities["exception.execution"]["status"] == "blocked"
    assert capabilities["exception.execution"]["reason"] =~ "raise/rescue"
    assert capabilities["struct.schema_compile"]["status"] == "executable"
    assert capabilities["struct.schema_compile"]["gate"] == "compile_probe"
    assert capabilities["struct.schema_compile"]["scope"] =~ "current-module defstruct"

    assert capabilities["guard.byte_size"]["status"] == "executable"
    assert capabilities["guard.byte_size"]["gate"] == "guard_byte_size_test"
    assert capabilities["guard.expanded_unit_range"]["gate"] == "generated_range_guard_test"
    assert capabilities["guard.expanded_unit_range"]["scope"] =~ "step 1 or -1"
    assert capabilities["guard.is_function"]["status"] == "executable"
    assert capabilities["guard.is_function"]["gate"] == "execute_test"
    assert capabilities["guard.is_function"]["scope"] =~ "module-local"
    assert capabilities["jason.unmodified"]["owner"] == "frontend"
    assert capabilities["fixture.second"]["status"] == "executable"
    assert capabilities["fixture.second"]["gate"] == "decimal_subset_test"
  end

  test "pins JSONTestSuite as data corpus rather than implementation fixture" do
    source = "probe/json_test_suite/source.json" |> File.read!() |> JSON.decode!()

    assert source["commit"] =~ ~r/^[0-9a-f]{40}$/
    assert source["role"] =~ "input/output corpus"
  end
end
