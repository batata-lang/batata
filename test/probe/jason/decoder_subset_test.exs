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
    {"integer token", "12345", 12_345},
    {"negative integer token", "-42", -42},
    {"fraction and exponent token", "12.5e+2", 7},
    {"true literal", "true", true},
    {"false literal", "false", false},
    {"null literal", "null", nil},
    {"quoted ASCII string", ~s("abc"), "abc"},
    {"quoted UTF-8 string", ~s("é中"), "é中"},
    {"empty array", "[]", 20},
    {"empty object", "{}", %{}},
    {"shallow array", "[true,null]", [true, nil]},
    {"shallow object", ~s({"ok":true}), %{"ok" => true}},
    {"recursive containers", ~s([{"ok":[true,null]}]), [%{"ok" => [true, nil]}]},
    {"rejects unterminated string", ~s("abc), 99},
    {"rejects trailing content", "true!", {:error, :invalid_json}},
    {"rejects trailing integer content", "123x", 99},
    {"rejects unknown token", "wat", {:error, :invalid_json}}
  ]

  for {name, input, expected} <- @cases do
    expected = Macro.escape(expected)

    test name, %{ctx: ctx} do
      source = JasonDecoderSubset.source(unquote(input))
      assert unquote(expected) == beam_result(source)
      assert unquote(expected) == Batata.execute(source, ctx)
    end
  end

  test "threads dynamic value/rest tuples through a recursive array parser", %{ctx: ctx} do
    source = JasonDecoderSubset.cursor_source("[1,[2,3],true,null]")
    expected = [1, [2, 3], true, nil]

    assert expected == beam_result(source)
    assert expected == Batata.execute(source, ctx)
  end

  test "constructs object entries from runtime parser values", %{ctx: ctx} do
    source = JasonDecoderSubset.map_source(~s({"a":1,"b":true}))
    expected = %{"a" => false, "b" => true}

    assert expected == beam_result(source)
    assert expected == Batata.execute(source, ctx)
  end

  test "constructs escaped string bytes at runtime", %{ctx: ctx} do
    source = JasonDecoderSubset.escape_source(~s("a\\n\\"b"))
    expected = "b\"\na"

    assert expected == beam_result(source)
    assert expected == Batata.execute(source, ctx)
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
