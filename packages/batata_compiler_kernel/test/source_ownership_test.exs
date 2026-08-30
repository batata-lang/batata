defmodule Batata.CompilerKernel.SourceOwnershipTest do
  use ExUnit.Case, async: true

  alias Batata.CompilerKernel

  test "compiled Batata source owns the complete pattern registry" do
    source = File.read!(CompilerKernel.conversion_source_path())
    adapter = File.read!(CompilerKernel.native_adapter_path())

    for function <- ~w(
      pattern_count pattern_namespace_length pattern_namespace_word
      pattern_root_length pattern_root_word pattern_target pattern_action
    ) do
      assert source =~ "def #{function}"
    end

    refute adapter =~ "BATATA_PATTERN("
    refute adapter =~ "static const BatataPattern patterns[]"
    refute adapter =~ ~r/"(?:batata\.)?ex\.[^"]+"/
  end
end
