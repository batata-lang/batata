defmodule Batata.EnumReduceLocalCaptureTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Beaver.MLIR

  @source """
  defmodule EnumReduceLocalCaptureFixture do
    defp prepend(acc, item), do: [item | acc]
    defp add(item, acc), do: item + acc

    defp reduce_terms(values, acc) do
      Enum.reduce(values, acc, &prepend(&2, &1))
    end

    def main() do
      {
        reduce_terms([], [:seed]),
        reduce_terms([:a], []),
        reduce_terms([:a, :b], [:seed]),
        Enum.reduce(1..4, 10, &add/2)
      }
    end
  end
  """

  test "executes local reducer captures with BEAM semantics", %{ctx: ctx} do
    expected =
      @source
      |> Kernel.<>("\nEnumReduceLocalCaptureFixture.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(@source, ctx) == expected
  end

  test "preserves tagged terms in an anonymous general reducer", %{ctx: ctx} do
    source = """
    defmodule EnumReduceTermFixture do
      def main(), do: Enum.reduce([:a, :b], [], fn item, acc -> [item | acc] end)
    end
    """

    assert Batata.execute(source, ctx) == [:b, :a]
  end

  test "emits a verified term-aware local reducer loop", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)
    assert MLIR.verify?(module)

    ir = MLIR.to_string(module, generic: true)
    assert ir =~ ~s{"ex.enumerable_to_list"}
    assert ir =~ ~s{"ex.enumerable_to_list_range"}
    assert ir =~ ~s{"scf.while"}
    assert ir =~ ~s{"ex.call"}
    refute ir =~ ~s{"ex.enumerable_reduce_fun"}
  end

  test "resumes a local reducer loop under a bounded reduction budget", %{ctx: ctx} do
    source = """
    defmodule EnumReduceBudgetFixture do
      defp prepend(acc, item), do: [item | acc]
      def main(), do: Enum.reduce([:a, :b, :c, :d], [], &prepend(&2, &1))
    end
    """

    assert Batata.execute(source, ctx, reduction_budget: 1) == [:d, :c, :b, :a]
  end
end
