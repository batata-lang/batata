defmodule Batata.ListDuplicateTest do
  use Batata.Case, async: true, group: :execution_engine

  @source """
  defmodule ListDuplicateFixture do
    def duplicate(item, count), do: List.duplicate(item, count)

    def main() do
      {duplicate(:value, 3), duplicate({:ok, [1, 2]}, 2)}
    end
  end
  """

  test "duplicates arbitrary runtime terms with BEAM semantics", %{ctx: ctx} do
    expected = {List.duplicate(:value, 3), List.duplicate({:ok, [1, 2]}, 2)}
    assert Batata.execute(@source, ctx) == expected
    assert Batata.execute(@source, ctx, reduction_budget: 1) == expected
  end

  test "lowers construction as a bounded-allocation loop", %{ctx: ctx} do
    ir = @source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)
    assert ir =~ ~s{"scf.while"}
    assert ir =~ ~s{"ex.list_cons"}
    assert ir =~ ~s{"arith.select"}
  end

  for {label, count} <- [
        {"zero", "0"},
        {"negative", "-1"},
        {"float", "1.0"},
        {"atom", ":bad"}
      ] do
    test "raises FunctionClauseError for #{label} count", %{ctx: ctx} do
      source = """
      defmodule InvalidListDuplicateFixture do
        def main(), do: List.duplicate(:value, #{unquote(count)})
      end
      """

      error = assert_raise FunctionClauseError, fn -> Batata.execute(source, ctx) end
      assert error.module == List
      assert error.function == :duplicate
      assert error.arity == 2
    end
  end
end
