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

      def null(), do: nil

      def decode(<<116, 114, 117, 101>>), do: true
      def decode(<<102, 97, 108, 115, 101>>), do: false
      def decode(<<110, 117, 108, 108>>), do: null()
      def decode(<<91, 93>>), do: 20
      def decode(<<123, 125>>), do: %{}
      def decode(<<91, 116, 114, 117, 101, 44, 110, 117, 108, 108, 93>>),
        do: [true, null()]
      def decode(<<123, 34, 111, 107, 34, 58, 116, 114, 117, 101, 125>>),
        do: %{"ok" => true}
      def decode(<<34, 97, 98, 99, 34>>), do: "abc"
      def decode(<<34, 195, 169, 228, 184, 173, 34>>), do: "é中"
      def decode(<<34, 97, 92, 34, 98, 34>>), do: <<97, 34, 98>>
      def decode(<<49, 50, 51, 52, 53>>), do: 12345
      def decode(<<45, 52, 50>>), do: 0 - 42
      def decode(<<34, rest::binary>>), do: string(rest, 0)
      def decode(<<byte::8, rest::binary>>) when byte in ?0..?9,
        do: number(rest, 1)
      def decode(_), do: 99


      def main(), do: decode(#{inspect(input)})
    end
    """
  end
end
