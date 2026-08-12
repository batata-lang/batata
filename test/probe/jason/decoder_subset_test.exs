defmodule Batata.Probe.Jason.DecoderSubsetTest do
  @moduledoc """
  Executable decoder kernels derived from Jason 1.4.5 scanner shapes.

  This is the first decoder subset gate, not a claim that unmodified Jason
  compiles. It exercises multi-clause binary dispatch, byte/rest cursors,
  integer range and character-set guards, and UTF-8 validation through both
  Batata and the BEAM oracle.
  """

  use Batata.Case, async: true

  alias Batata
  alias Batata.Test.JasonDecoderSubset

  @cases [
    {"integer token", "12345", 5},
    {"negative integer token", "-42", 3},
    {"fraction and exponent token", "12.5e+2", 7},
    {"true literal", "true", 10},
    {"false literal", "false", 11},
    {"null literal", "null", 12},
    {"quoted ASCII string", ~s("abc"), 3},
    {"quoted UTF-8 string", ~s("é中"), 2},
    {"empty array", "[]", 20},
    {"empty object", "{}", 21},
    {"rejects unterminated string", ~s("abc), 99},
    {"rejects trailing content", "true!", 99},
    {"rejects unknown token", "wat", 99}
  ]

  for {name, input, expected} <- @cases do
    test name, %{ctx: ctx} do
      source = JasonDecoderSubset.source(unquote(input))
      assert unquote(expected) == beam_result(source)
      assert unquote(expected) == Batata.execute(source, ctx)
    end
  end

  defp beam_result(source) do
    [{module, _binary}] = Code.compile_string(source)

    try do
      module.main()
    after
      :code.purge(module)
      :code.delete(module)
    end
  end
end
