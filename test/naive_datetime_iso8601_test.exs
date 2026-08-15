defmodule Batata.NaiveDateTimeIso8601Test do
  use Batata.Case, async: true

  @datetimes [
    {-9999, 1, 1, 0, 0, 0, {0, 0}},
    {-1, 1, 2, 12, 34, 56, {0, 0}},
    {1, 1, 2, 1, 2, 3, {0, 0}},
    {1900, 2, 28, 23, 59, 59, {0, 0}},
    {2000, 2, 29, 12, 34, 56, {0, 6}},
    {2020, 2, 29, 1, 2, 3, {5, 6}},
    {2024, 1, 2, 12, 34, 56, {500_000, 3}},
    {2024, 1, 2, 1, 2, 3, {123_456, 3}},
    {2024, 1, 2, 1, 2, 3, {123_000, 3}},
    {2024, 1, 2, 1, 2, 3, {100, 3}},
    {2024, 1, 2, 1, 2, 3, {999_999, 0}},
    {2024, 1, 2, 1, 2, 3, {1, 1}},
    {2024, 1, 2, 1, 2, 3, {123_456, 2}},
    {2024, 1, 2, 1, 2, 3, {123_456, 4}},
    {2024, 1, 2, 1, 2, 3, {123_456, 5}},
    {9999, 12, 31, 23, 59, 59, {999_999, 6}}
  ]

  @max_packed 6_311_074_175_999_999_996

  test "formats the closed packed NaiveDateTime range with BEAM precision", %{ctx: ctx} do
    calls = Enum.map_join(@datetimes, ", ", &datetime_call/1)

    source = """
    defmodule NaiveDateTimeIso8601Oracle do
      def main(), do: [#{calls}]
    end
    """

    expected =
      Enum.map(@datetimes, fn {year, month, day, hour, minute, second, microsecond} ->
        year
        |> NaiveDateTime.new!(month, day, hour, minute, second, microsecond)
        |> NaiveDateTime.to_iso8601()
      end)

    assert Batata.execute(source, ctx) == expected
  end

  test "locks the packed i64 boundaries", %{ctx: ctx} do
    source = """
    defmodule NaiveDateTimeIso8601Boundaries do
      def main() do
        [NaiveDateTime.to_iso8601(0), NaiveDateTime.to_iso8601(#{@max_packed})]
      end
    end
    """

    assert Batata.execute(source, ctx) == [
             "-9999-01-01T00:00:00",
             "9999-12-31T23:59:59.999999"
           ]
  end

  test "executes a Jason-shaped NaiveDateTime encoder body against the packed slice", %{
    ctx: ctx
  } do
    source = """
    defmodule NaiveDateTimeIso8601JasonOracle do
      defp struct(value, _escape, _encode_map, NaiveDateTime) do
        [?\", NaiveDateTime.to_iso8601(value), ?\"]
      end

      def main() do
        struct(
          NaiveDateTime.new(2024, 1, 2, 12, 34, 56, {5, 6}),
          :unused,
          %{},
          :"Elixir.NaiveDateTime"
        )
      end
    end
    """

    expected =
      [?\", NaiveDateTime.to_iso8601(NaiveDateTime.new!(2024, 1, 2, 12, 34, 56, {5, 6})), ?\"]

    assert Batata.execute(source, ctx) == expected
  end

  test "fails closed outside the packed NaiveDateTime representation", %{ctx: ctx} do
    for value <- [
          "0 - 1",
          Integer.to_string(@max_packed + 1),
          "7",
          "8",
          "9",
          ~s("not a datetime")
        ] do
      assert_raise ArgumentError, fn ->
        Batata.execute(
          """
          defmodule NaiveDateTimeIso8601InvalidValue do
            def main(), do: NaiveDateTime.to_iso8601(#{value})
          end
          """,
          ctx
        )
      end
    end
  end

  test "rejects invalid, dynamic, and unsupported NaiveDateTime constructors", %{ctx: ctx} do
    invalid_calls = [
      "NaiveDateTime.new(2024, 2, 30, 1, 2, 3)",
      "NaiveDateTime.new(2024, 1, 2, 24, 0, 0)",
      "NaiveDateTime.new(2024, 1, 2, 1, 2, 3, {-1, 6})",
      "NaiveDateTime.new(2024, 1, 2, 1, 2, 3, {0, 7})",
      "year = 2024\nNaiveDateTime.new(year, 1, 2, 1, 2, 3)",
      "NaiveDateTime.new(10_000, 1, 1, 0, 0, 0)",
      "NaiveDateTime.new(-10_000, 1, 1, 0, 0, 0)",
      "NaiveDateTime.new(Date.new(2024, 1, 2), Time.new(1, 2, 3))",
      "NaiveDateTime.new(2024, 1, 2, 1, 2, 3, {0, 0}, Calendar.ISO)"
    ]

    for call <- invalid_calls do
      assert_raise Batata.Lift.Error,
                   ~r/NaiveDateTime.new requires valid integer literal arguments in this slice/,
                   fn ->
                     Batata.execute(
                       """
                       defmodule NaiveDateTimeIso8601InvalidConstructor do
                         def main() do
                           #{call}
                         end
                       end
                       """,
                       ctx
                     )
                   end
    end
  end

  defp datetime_call({year, month, day, hour, minute, second, {0, 0}}) do
    "NaiveDateTime.to_iso8601(" <>
      "NaiveDateTime.new(#{year}, #{month}, #{day}, #{hour}, #{minute}, #{second}))"
  end

  defp datetime_call({year, month, day, hour, minute, second, {microsecond, precision}}) do
    "NaiveDateTime.to_iso8601(" <>
      "NaiveDateTime.new(#{year}, #{month}, #{day}, #{hour}, #{minute}, #{second}, " <>
      "{#{microsecond}, #{precision}}))"
  end
end
