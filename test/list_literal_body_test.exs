defmodule Batata.ListLiteralBodyTest do
  use Batata.Case, async: true

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
end
