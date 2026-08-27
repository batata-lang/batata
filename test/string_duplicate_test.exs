defmodule Batata.StringDuplicateTest do
  use Batata.Case, async: true, group: :execution_engine

  for {label, expression, expected} <- [
        {"positive count", ~S|String.duplicate("ab", 3)|, "ababab"},
        {"zero count", ~S|String.duplicate("ab", 0)|, ""},
        {"empty binary and large count", ~S|String.duplicate("", 10_000_000)|, ""},
        {"UTF-8 binary", ~S|String.duplicate("é", 2)|, "éé"}
      ] do
    test "folds compile-known String.duplicate/2 with #{label}", %{ctx: ctx} do
      source = """
      defmodule StringDuplicateFixture do
        def main() do
          #{unquote(expression)}
        end
      end
      """

      assert Batata.execute(source, ctx) == unquote(expected)
    end
  end

  test "rejects invalid or dynamic arguments", %{ctx: ctx} do
    invalid_sources = [
      "String.duplicate(\"x\", -1)",
      "String.duplicate(:x, 2)",
      "String.duplicate(\"x\", 1.0)",
      "String.duplicate(value, 2)",
      "String.duplicate(\"x\", value)"
    ]

    Enum.each(invalid_sources, fn expression ->
      source = """
      defmodule InvalidStringDuplicateFixture do
        def run(value), do: #{expression}
      end
      """

      assert_raise Batata.Lift.Error,
                   ~r/String\.duplicate\/2 requires a compile-known binary and non-negative integer count/,
                   fn -> Batata.execute(source, ctx, args: ["x"]) end
    end)
  end

  test "rejects oversized compile-known output before allocation", %{ctx: ctx} do
    source = """
    defmodule OversizedStringDuplicateFixture do
      def run(value), do: {value, String.duplicate("ab", 524_289)}
    end
    """

    assert_raise Batata.Lift.Error,
                 ~r/compile-known result exceeds the 1048576-byte limit: 1048578 bytes/,
                 fn -> Batata.execute(source, ctx, args: [0]) end
  end
end
