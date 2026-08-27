defmodule Batata.ListLiteralBodyTest do
  use Batata.Case, async: true, group: :execution_engine

  test "preserves a list literal as a function body", %{ctx: ctx} do
    source = """
    defmodule ListLiteralBody do
      defp wrapped(), do: [?\", "body", ?\"]
      def main(), do: wrapped()
    end
    """

    assert Batata.execute(source, ctx) == [?\", "body", ?\"]
  end

  test "continues to execute multi-expression function bodies", %{ctx: ctx} do
    source = """
    defmodule BlockBody do
      def main() do
        value = 40
        value + 2
      end
    end
    """

    assert Batata.execute(source, ctx) == 42
  end

  test "preserves a list literal in a multi-argument function clause", %{ctx: ctx} do
    source = """
    defmodule MultiArgumentListLiteralBody do
      defp wrapped(value, :tag), do: [?\", value, ?\"]
      def main(), do: wrapped(98, :tag)
    end
    """

    assert Batata.execute(source, ctx) == [?\", 98, ?\"]
  end
end
