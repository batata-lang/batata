defmodule Batata.Binary64FloatSegmentTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Beaver.MLIR

  @source """
  defmodule Binary64FloatSegment do
    def decode(binary) do
      case binary do
        <<value::float>> -> value
        _ -> :no_match
      end
    end

    def pack(sign, exponent, fraction) do
      <<sign::size(1), exponent::size(11), fraction::size(52)>>
    end

    def main() do
      {
        decode(pack(0, 1023, 0)),
        decode(pack(1, 0, 0)),
        decode(pack(1, 1026, 2_533_274_790_395_904)),
        decode(pack(0, 2047, 0)),
        decode(pack(3, 3071, 4_503_599_627_370_496)),
        decode(<<1, 2>>)
      }
    end
  end
  """

  test "packs and matches binary64 values against the BEAM oracle", %{ctx: ctx} do
    expected = beam_result(@source)
    actual = Batata.execute(@source, ctx)

    assert :erlang.term_to_binary(actual) == :erlang.term_to_binary(expected)
    assert elem(actual, 3) == :no_match
    assert elem(actual, 5) == :no_match
  end

  test "emits verified scalar packing and boxed float construction", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    assert MLIR.verify?(module)

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "arith.shli"
    assert rendered =~ "arith.shrui"
    assert rendered =~ "arith.andi"
    assert rendered =~ "ex.binary_get"
    assert rendered =~ "ex.binary"
    assert rendered =~ "ex.float_lit"
  end

  test "rejects dynamic, non-64-bit, and non-integer bitfields", %{ctx: ctx} do
    compile_errors = [
      {"dynamic width",
       """
       defmodule DynamicBitfield do
         def main() do
           width = 64
           <<1::size(width)>>
         end
       end
       """},
      {"short total",
       """
        defmodule ShortBitfield do
          def pack(value), do: <<value::size(8)>>
          def main(), do: pack(1)
        end
       """}
    ]

    for {label, source} <- compile_errors do
      try do
        Batata.compile(source, ctx)
        flunk("#{label} bitfield was accepted")
      rescue
        Batata.Lift.Error -> :ok
      end
    end

    non_integer = """
    defmodule NonIntegerBitfield do
      def main() do
        value = {:not, :integer}
        <<value::size(64)>>
      end
    end
    """

    assert_raise ArgumentError, fn -> Batata.execute(non_integer, ctx) end
  end

  test "rejects unsupported float modifiers explicitly", %{ctx: ctx} do
    source = """
    defmodule Float32Pattern do
      def decode(<<value::float-size(32)>>), do: value
      def decode(_), do: :no_match
      def main(), do: decode(<<0, 0, 0, 0>>)
    end
    """

    assert_raise Batata.Lift.Error, ~r/unsupported binary segment/, fn ->
      Batata.compile(source, ctx)
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
