defmodule Batata.DecimalParseShapeTest do
  use Batata.Case, async: true, group: :execution_engine

  @source """
  defmodule DecimalParseShape do
    def parse(binary) do
      {int, rest} = parse_digits(binary)
      {fraction, rest} = parse_fraction(rest)
      {List.to_integer(int ++ fraction), 0 - length(fraction), rest}
    end

    defp parse_fraction("." <> rest), do: parse_digits(rest)
    defp parse_fraction(binary), do: {[], binary}

    defp parse_digits(binary), do: parse_digits(binary, [])

    defp parse_digits(<<digit, rest::binary>>, acc) when digit in ?0..?9 do
      parse_digits(rest, [digit | acc])
    end

    defp parse_digits(rest, acc), do: {:lists.reverse(acc), rest}

    def main(), do: {parse("12.30"), parse("42")}
  end
  """

  test "preserves parsed digit lists across recursive helpers", %{ctx: ctx} do
    source =
      String.replace(
        @source,
        ~S|def main(), do: {parse("12.30"), parse("42")}|,
        ~S|def main(), do: {parse_digits("12.30"), parse_fraction(".30")}|
      )

    assert Batata.execute(source, ctx) == {{~c"12", ".30"}, {~c"30", ""}}
  end

  test "parses Decimal-shaped integer and fractional digit lists", %{ctx: ctx} do
    assert Batata.execute(@source, ctx) == {{1230, -2, ""}, {42, 0, ""}}
  end
end
