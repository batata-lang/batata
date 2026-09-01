defmodule Batata.ListsSplitTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Beaver.MLIR

  test "splits proper and improper lists with BEAM semantics", %{ctx: ctx} do
    source = """
    defmodule ListsSplitFixture do
      def main() do
        {
          case :lists.split(0, []) do
            {[], []} -> :zero_empty
            _other -> :mismatch
          end,
          case :lists.split(0, [1 | :tail]) do
            {[], [1 | :tail]} -> :zero_improper
            _other -> :mismatch
          end,
          :lists.split(2, [1, 2, 3, 4]),
          case :lists.split(4, [1, 2, 3, 4]) do
            {[1, 2, 3, 4], []} -> :full
            _other -> :mismatch
          end,
          :lists.split(2, [1, 2 | :tail])
        }
      end
    end
    """

    expected = {
      :zero_empty,
      :zero_improper,
      {[1, 2], [3, 4]},
      :full,
      {[1, 2], :tail}
    }

    assert Batata.execute(source, ctx) == expected
    assert Batata.execute(source, ctx, reduction_budget: 1) == expected
  end

  test "raises ArgumentError for invalid counts and insufficient lists", %{ctx: ctx} do
    for expression <- [
          ":lists.split(-1, [1])",
          ":lists.split(:bad, [1])",
          ":lists.split(0, :not_a_list)",
          ":lists.split(2, [1])"
        ] do
      source = """
      defmodule InvalidListsSplitFixture do
        def main(), do: #{expression}
      end
      """

      assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
    end
  end

  test "lowers to bounded list cursor loops and a tuple result", %{ctx: ctx} do
    source = """
    defmodule ListsSplitIRFixture do
      def main(), do: :lists.split(2, [1, 2, 3])
    end
    """

    module = Batata.compile(source, ctx)
    assert MLIR.verify?(module)
    rendered = MLIR.to_string(module, generic: true)
    assert length(Regex.scan(~r/"scf.while"/, rendered)) == 2
    assert rendered =~ ~s{"ex.list_head"}
    assert rendered =~ ~s{"ex.list_tail"}
    assert rendered =~ ~s{"ex.list_cons"}
    assert rendered =~ ~s{"ex.tuple"}
  end
end
