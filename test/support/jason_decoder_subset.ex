defmodule Batata.Test.JasonDecoderSubset do
  @moduledoc false

  def source(input) do
    """
    defmodule JasonDecoderSubset do
      def digits(<<>>, value), do: value
      def digits(<<byte::8, rest::binary>>, value) when byte in ?0..?9,
        do: digits(rest, value * 10 + byte - ?0)
      def digits(_, value), do: value * 0 + 99

      def negative_digits(<<byte::8, rest::binary>>) when byte in ?0..?9,
        do: negative(rest, 0 - (byte - ?0))
      def negative_digits(_), do: {:error, :invalid_json}

      def negative(<<>>, value), do: value
      def negative(<<byte::8, rest::binary>>, value) when byte in ?0..?9,
        do: negative(rest, value * 10 - (byte - ?0))
      def negative(_, value), do: value * 0 + 99

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
      def decode(<<91, 123, 34, 111, 107, 34, 58, 91, 116, 114, 117, 101, 44, 110, 117,
                   108, 108, 93, 125, 93>>),
        do: [%{"ok" => [true, null()]}]
      def decode(<<34, 97, 98, 99, 34>>), do: "abc"
      def decode(<<34, 195, 169, 228, 184, 173, 34>>), do: "é中"
      def decode(<<34, 97, 92, 34, 98, 34>>), do: <<97, 34, 98>>
      def decode(<<49, 50, 46, 53, 101, 43, 50>>), do: 7
      def decode(<<34, rest::binary>>), do: string(rest, 0)
      def decode(<<45, rest::binary>>), do: negative_digits(rest)
      def decode(<<byte::8, rest::binary>>) when byte in ?0..?9,
        do: digits(rest, byte - ?0)
      def decode(_), do: {:error, :invalid_json}


      def main(), do: decode(#{inspect(input)})
    end
    """
  end

  def cursor_source(input) do
    """
    defmodule JasonCursorDecoderSubset do
      def parse_value(<<116, 114, 117, 101, rest::binary>>), do: {true, rest}
      def parse_value(<<102, 97, 108, 115, 101, rest::binary>>), do: {false, rest}
      def parse_value(<<110, 117, 108, 108, rest::binary>>), do: {nil, rest}
      def parse_value(<<91, rest::binary>>), do: parse_array(rest)
      def parse_value(<<byte::8, rest::binary>>) when byte in ?0..?9,
        do: {byte - ?0, rest}
      def parse_value(rest), do: {{:error, :invalid_json}, rest}

      def parse_array(<<93, rest::binary>>), do: {[], rest}
      def parse_array(binary) do
        {value, rest} = parse_value(binary)
        parse_array_tail(rest, value)
      end

      def parse_array_tail(<<93, rest::binary>>, value), do: {[value | []], rest}
      def parse_array_tail(<<44, rest::binary>>, value) do
        {tail, rest} = parse_array(rest)
        {[value | tail], rest}
      end
      def parse_array_tail(rest, value), do: {{:error, value}, rest}

      def decode(binary) do
        {value, rest} = parse_value(binary)

        case rest do
          <<>> -> value
          _ -> {:error, :invalid_json}
        end
      end

      def main(), do: decode(#{inspect(input)})
    end
    """
  end

  def map_source(input) do
    """
    defmodule JasonDynamicMapSubset do
      def first_key(), do: "a"
      def second_key(), do: "b"
      def first_value(), do: false
      def second_value(), do: true

      def decode(<<123, 34, 97, 34, 58, 49, 44, 34, 98, 34, 58, 116, 114, 117, 101, 125>>) do
        map = Map.put(%{}, first_key(), first_value())
        Map.put(map, second_key(), second_value())
      end
      def decode(_), do: {:error, :invalid_json}

      def main(), do: decode(#{inspect(input)})
    end
    """
  end
end
