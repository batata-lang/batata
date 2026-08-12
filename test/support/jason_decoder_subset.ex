defmodule Batata.Test.JasonDecoderSubset do
  @moduledoc false

  def source(input) do
    """
    defmodule JasonDecoderSubset do
      def number(<<>>, count), do: count
      def number(<<byte::8, rest::binary>>, count) when byte in ?0..?9,
        do: number(rest, count + 1)
      def number(<<byte::8, rest::binary>>, count) when byte in ~c"eE+-." ,
        do: number(rest, count + 1)
      def number(_, count), do: count * 0 + 99

      def string(<<34>>, count), do: count
      def string(<<_char::utf8, rest::binary>>, count), do: string(rest, count + 1)
      def string(_, count), do: count * 0 + 99

      def decode(<<116, 114, 117, 101>>), do: 10
      def decode(<<102, 97, 108, 115, 101>>), do: 11
      def decode(<<110, 117, 108, 108>>), do: 12
      def decode(<<91, 93>>), do: 20
      def decode(<<123, 125>>), do: 21
      def decode(<<34, rest::binary>>), do: string(rest, 0)
      def decode(<<45, rest::binary>>), do: number(rest, 1)
      def decode(<<byte::8, rest::binary>>) when byte in ?0..?9,
        do: number(rest, 1)
      def decode(_), do: 99

      def main(), do: decode(#{inspect(input)})
    end
    """
  end
end
