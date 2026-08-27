defmodule Batata.DateIso8601Test do
  use Batata.Case, async: true, group: :execution_engine

  test "formats Gregorian day values across the supported Date range", %{ctx: ctx} do
    dates = [
      {-9999, 1, 1},
      {-1, 1, 2},
      {0, 1, 1},
      {1, 1, 2},
      {1900, 2, 28},
      {2000, 2, 29},
      {2020, 2, 29},
      {9999, 12, 31}
    ]

    days =
      Enum.map(dates, fn {year, month, day} -> Calendar.ISO.date_to_iso_days(year, month, day) end)

    source = """
    defmodule DateIso8601Oracle do
      def main() do
        [#{Enum.map_join(days, ", ", &("Date.to_iso8601(" <> day_expression(&1) <> ")"))}]
      end
    end
    """

    expected =
      Enum.map(dates, fn {year, month, day} ->
        year |> Date.new!(month, day) |> Date.to_iso8601()
      end)

    assert Batata.execute(source, ctx) == expected
  end

  test "executes a Jason-shaped Date encoder body", %{ctx: ctx} do
    source = """
    defmodule DateIso8601JasonOracle do
      defp struct(value, _escape, _encode_map, Date) do
        [?\", Date.to_iso8601(value), ?\"]
      end

      def main() do
        struct(Date.new(2024, 1, 2), :unused, %{}, :"Elixir.Date")
      end
    end
    """

    expected = [?\", Date.to_iso8601(Date.new!(2024, 1, 2)), ?\"]
    assert Batata.execute(source, ctx) == expected
  end

  test "fails closed outside the supported Date year range", %{ctx: ctx} do
    too_early = Calendar.ISO.date_to_iso_days(-10_000, 12, 31)
    too_late = Calendar.ISO.date_to_iso_days(10_000, 1, 1)

    for days <- [too_early, too_late] do
      assert_raise ArgumentError, fn ->
        Batata.execute(
          """
          defmodule DateIso8601OutOfRange do
            def main(), do: Date.to_iso8601(#{day_expression(days)})
          end
          """,
          ctx
        )
      end
    end
  end

  defp day_expression(days) when days < 0, do: "0 - #{abs(days)}"
  defp day_expression(days), do: Integer.to_string(days)
end
