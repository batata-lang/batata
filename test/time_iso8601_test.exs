defmodule Batata.TimeIso8601Test do
  use Batata.Case, async: true, group: :execution_engine

  @times [
    {0, 0, 0, {0, 0}},
    {23, 59, 59, {999_999, 6}},
    {12, 34, 56, {0, 0}},
    {1, 2, 3, {0, 6}},
    {1, 2, 3, {5, 6}},
    {1, 2, 3, {500_000, 3}},
    {1, 2, 3, {123_456, 3}},
    {1, 2, 3, {123_000, 3}},
    {1, 2, 3, {100, 3}},
    {1, 2, 3, {999_999, 0}},
    {1, 2, 3, {1, 1}},
    {1, 2, 3, {123_456, 2}},
    {1, 2, 3, {123_456, 4}},
    {1, 2, 3, {123_456, 5}}
  ]

  test "formats packed Time values with BEAM microsecond precision", %{ctx: ctx} do
    calls = Enum.map_join(@times, ", ", &time_call/1)

    source = """
    defmodule TimeIso8601Oracle do
      def main(), do: [#{calls}]
    end
    """

    expected =
      Enum.map(@times, fn {hour, minute, second, microsecond} ->
        hour |> Time.new!(minute, second, microsecond) |> Time.to_iso8601()
      end)

    assert Batata.execute(source, ctx) == expected
  end

  test "executes a Jason-shaped Time encoder body", %{ctx: ctx} do
    source = """
    defmodule TimeIso8601JasonOracle do
      defp struct(value, _escape, _encode_map, Time) do
        [?\", Time.to_iso8601(value), ?\"]
      end

      def main() do
        struct(Time.new(1, 2, 3, {5, 6}), :unused, %{}, :"Elixir.Time")
      end
    end
    """

    expected = [?\", Time.to_iso8601(Time.new!(1, 2, 3, {5, 6})), ?\"]
    assert Batata.execute(source, ctx) == expected
  end

  test "fails closed for values outside the packed Time representation", %{ctx: ctx} do
    for value <- ["0 - 1", "863_999_999_997", "864_000_000_000", ~s("not a time")] do
      assert_raise ArgumentError, fn ->
        Batata.execute(
          """
          defmodule TimeIso8601InvalidValue do
            def main(), do: Time.to_iso8601(#{value})
          end
          """,
          ctx
        )
      end
    end
  end

  test "rejects invalid or dynamic Time constructors at the frontend", %{ctx: ctx} do
    invalid_calls = [
      "Time.new(24, 0, 0)",
      "Time.new(1, 60, 0)",
      "Time.new(1, 2, 60)",
      "Time.new(1, 2, 3, {-1, 6})",
      "Time.new(1, 2, 3, {0, 7})",
      "Time.new(1, 2, 3, {1_000_000, 6})",
      "hour = 1\nTime.new(hour, 2, 3)"
    ]

    for call <- invalid_calls do
      assert_raise Batata.Lift.Error,
                   ~r/Time.new requires valid integer literal arguments in this slice/,
                   fn ->
                     Batata.execute(
                       """
                       defmodule TimeIso8601InvalidConstructor do
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

  defp time_call({hour, minute, second, {0, 0}}),
    do: "Time.to_iso8601(Time.new(#{hour}, #{minute}, #{second}))"

  defp time_call({hour, minute, second, {microsecond, precision}}) do
    "Time.to_iso8601(Time.new(#{hour}, #{minute}, #{second}, " <>
      "{#{microsecond}, #{precision}}))"
  end
end
