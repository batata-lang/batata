defmodule Batata.FixedBinaryPatternTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Beaver.MLIR

  @source """
  defmodule FixedBinaryPattern do
    def split(<<first, middle::size(2)-binary, rest::binary>>),
      do: {:split, first, middle, rest}

    def split(_value), do: :no_match

    def reverse_spec(<<prefix::binary-size(2), rest::binary>>), do: {prefix, rest}
    def reverse_spec(_value), do: :no_match

    def bytes_alias(<<prefix::bytes-size(2), rest::binary>>), do: {prefix, rest}
    def bytes_alias(_value), do: :no_match

    def followed_by_literal(<<prefix::binary-size(2), "cd", rest::binary>>),
      do: {prefix, rest}

    def followed_by_literal(_value), do: :no_match

    def exact(<<whole::binary-size(3)>>), do: whole
    def exact(_value), do: :no_match

    def main() do
      {
        split(<<1, 2, 3, 4, 5>>),
        split(<<1, 2>>),
        reverse_spec("abcd"),
        bytes_alias("abcd"),
        followed_by_literal("abcdef"),
        followed_by_literal("abxyef"),
        exact("abc"),
        exact("abcd"),
        exact("ab")
      }
    end
  end
  """

  test "matches fixed-size byte-aligned binary segments against the BEAM oracle", %{ctx: ctx} do
    expected = beam_result(@source)

    assert expected ==
             {
               {:split, 1, <<2, 3>>, <<4, 5>>},
               :no_match,
               {"ab", "cd"},
               {"ab", "cd"},
               {"ab", "ef"},
               :no_match,
               "abc",
               :no_match,
               :no_match
             }

    assert Batata.execute(@source, ctx) == expected
  end

  test "emits verified binary parts and retains the total length guard", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    assert MLIR.verify?(module)

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "ex.binary_part"
    assert rendered =~ "ex.binary_length"
    assert rendered =~ "ex.binary_slice"
  end

  test "keeps dynamic sizes and non-byte units unsupported", %{ctx: ctx} do
    sources = [
      """
      defmodule DynamicBinarySize do
        def main() do
          size = 2

          case "ab" do
            <<part::binary-size(size)>> -> part
            _value -> :no_match
          end
        end
      end
      """,
      """
      defmodule FixedBitSize do
        def split(<<part::bits-size(7)>>), do: part
        def split(_value), do: :no_match
        def main(), do: split(<<1::7>>)
      end
      """
    ]

    for source <- sources do
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
