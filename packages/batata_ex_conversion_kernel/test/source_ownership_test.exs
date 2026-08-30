defmodule Batata.ExConversionKernel.SourceOwnershipTest do
  use ExUnit.Case, async: true

  alias Batata.ExConversionKernel

  test "compiled Batata source owns the complete pattern registry" do
    source = File.read!(ExConversionKernel.conversion_source_path())
    adapter = File.read!(ExConversionKernel.native_adapter_path())

    for function <- ~w(
      pattern_count pattern_namespace_length pattern_namespace_word
      pattern_root_length pattern_root_word pattern_target pattern_action
    ) do
      assert source =~ "def #{function}"
    end

    refute adapter =~ "BATATA_PATTERN("
    refute adapter =~ "static const BatataPattern patterns[]"
    refute adapter =~ "BATATA_TARGET_"
    refute adapter =~ "BATATA_RUNTIME_"
    refute adapter =~ ~r/static MlirLogicalResult (?!source_rewrite)[a-z_]+_rewrite/
    refute adapter =~ ~r/"(?:batata\.)?ex\.[^"]+"/
  end
end
