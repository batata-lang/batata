defmodule Batata.DateTimeIso8601Test do
  use Batata.Case, async: true, group: :execution_engine

  @datetimes [
    {-9999, 1, 1, 0, 0, 0, {0, 0}},
    {-1, 1, 2, 12, 34, 56, {0, 0}},
    {1, 1, 2, 1, 2, 3, {0, 0}},
    {2000, 2, 29, 12, 34, 56, {0, 6}},
    {2024, 1, 2, 12, 34, 56, {5, 6}},
    {2024, 1, 2, 1, 2, 3, {123_000, 3}},
    {9999, 12, 31, 23, 59, 59, {999_999, 6}}
  ]

  @max_packed 6_311_074_175_999_999_996

  test "formats the closed UTC DateTime range with BEAM precision", %{ctx: ctx} do
    source = """
    defmodule DateTimeIso8601Oracle do
      def main(), do: [#{Enum.map_join(@datetimes, ", ", &datetime_call/1)}]
    end
    """

    expected = Enum.map(@datetimes, &beam_datetime/1)
    assert Batata.execute(source, ctx) == expected
  end

  test "locks the packed UTC boundaries", %{ctx: ctx} do
    source = """
    defmodule DateTimeIso8601Boundaries do
      def main() do
        [DateTime.to_iso8601(0), DateTime.to_iso8601(#{@max_packed})]
      end
    end
    """

    assert Batata.execute(source, ctx) == [
             "-9999-01-01T00:00:00Z",
             "9999-12-31T23:59:59.999999Z"
           ]
  end

  test "executes a Jason-shaped DateTime encoder body", %{ctx: ctx} do
    source = """
    defmodule DateTimeIso8601JasonOracle do
      defp struct(value, _escape, _encode_map, DateTime) do
        [?\", DateTime.to_iso8601(value), ?\"]
      end

      def main() do
        value =
          DateTime.from_naive!(
            NaiveDateTime.new!(2024, 1, 2, 12, 34, 56, {5, 6}),
            "Etc/UTC"
          )

        struct(value, :unused, %{}, DateTime)
      end
    end
    """

    expected = [?\", beam_datetime({2024, 1, 2, 12, 34, 56, {5, 6}}), ?\"]
    assert Batata.execute(source, ctx) == expected
  end

  test "fails closed outside the packed UTC representation", %{ctx: ctx} do
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
          defmodule DateTimeIso8601InvalidValue do
            def main(), do: DateTime.to_iso8601(#{value})
          end
          """,
          ctx
        )
      end
    end
  end

  test "rejects unsupported DateTime zones and constructor shapes", %{ctx: ctx} do
    calls = [
      ~s|DateTime.from_naive!(NaiveDateTime.new!(2024, 1, 2, 1, 2, 3), "Europe/Paris")|,
      ~s|DateTime.from_naive!(NaiveDateTime.new!(2024, 1, 2, 1, 2, 3), "UTC")|,
      "zone = \"Etc/UTC\"\n" <>
        "DateTime.from_naive!(NaiveDateTime.new!(2024, 1, 2, 1, 2, 3), zone)"
    ]

    for call <- calls do
      assert_raise Batata.Lift.Error,
                   ~r/DateTime.from_naive! only supports the literal Etc\/UTC zone/,
                   fn ->
                     Batata.execute(
                       """
                       defmodule DateTimeIso8601InvalidConstructor do
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

  defp datetime_call({year, month, day, hour, minute, second, {microsecond, precision}}) do
    "DateTime.to_iso8601(" <>
      "DateTime.from_naive!(" <>
      "NaiveDateTime.new!(#{year}, #{month}, #{day}, #{hour}, #{minute}, #{second}, " <>
      "{#{microsecond}, #{precision}}), \"Etc/UTC\"))"
  end

  defp beam_datetime({year, month, day, hour, minute, second, microsecond}) do
    year
    |> NaiveDateTime.new!(month, day, hour, minute, second, microsecond)
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end
end
