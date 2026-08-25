defmodule Batata.UInt16BinaryPatternTest do
  use Batata.Case, async: true

  alias Batata
  alias Beaver.MLIR

  @source """
  defmodule UInt16BinaryPattern do
    def decode(<<value::16>>), do: value
    def decode(_value), do: -1

    def literal(<<0xABCD::16>>), do: 1
    def literal(_value), do: 0

    def with_rest(<<value::16, rest::binary>>) when byte_size(rest) == 1 do
      value + byte_size(rest)
    end

    def with_rest(_value), do: -1

    def main() do
      {
        decode(<<0, 0>>),
        decode(<<0, 255>>),
        decode(<<1, 0>>),
        decode(<<255, 255>>),
        decode(<<1>>),
        decode(<<1, 2, 3>>),
        decode(:not_binary),
        literal(<<0xAB, 0xCD>>),
        literal(<<0xAB, 0xCE>>),
        with_rest(<<0x12, 0x34, 0>>),
        with_rest(<<0x12, 0x34>>)
      }
    end
  end
  """

  test "matches default unsigned big-endian 16-bit segments against the BEAM oracle", %{
    ctx: ctx
  } do
    expected = beam_result(@source)

    assert expected == {0, 255, 256, 65_535, -1, -1, -1, 1, 0, 4_661, -1}
    assert expected == Batata.execute(@source, ctx)
  end

  test "emits verified two-byte reads and integer composition", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    assert MLIR.verify?(module)

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "ex.binary_get"
    assert rendered =~ "ex.mul"
    assert rendered =~ "ex.add"
    assert rendered =~ "ex.binary_slice"
  end

  test "keeps signed, little-endian, and other fixed widths unsupported", %{ctx: ctx} do
    for spec <- ["signed-16", "little-16", "24"] do
      source = """
      defmodule UnsupportedBinaryPattern do
        def main() do
          case <<1, 2, 3>> do
            <<value::#{spec}>> -> value
            _value -> -1
          end
        end
      end
      """

      assert_raise Batata.Lift.Error, ~r/unsupported binary segment/, fn ->
        Batata.compile(source, ctx)
      end
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
