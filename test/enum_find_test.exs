defmodule Batata.EnumFindTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Beaver.MLIR

  @source """
  defmodule EnumFindFixture do
    defp wanted?(value), do: value == :direct

    def main() do
      context = %{traps: [:overflow, :invalid]}

      {
        Enum.find([], &wanted?/1),
        Enum.find([:other], &wanted?/1),
        Enum.find([:other, :direct, :later], &wanted?/1),
        Enum.find([:underflow, :invalid, :overflow], &(&1 in context.traps)),
        Enum.find(1..5, &(rem(&1, 2) == 0)),
        Enum.find([1, 2, 3], &(&1 == 2))
      }
    end
  end
  """

  test "matches the BEAM oracle for local and captured predicates", %{ctx: ctx} do
    expected = @source |> Kernel.<>("\nEnumFindFixture.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(@source, ctx) == expected
  end

  test "stops after the first match", %{ctx: ctx} do
    source = """
    defmodule EnumFindEarlyStopFixture do
      def main() do
        result = Enum.find([1, 2, 3], fn value ->
          send(self(), value)
          value == 2
        end)

        first = receive do value -> value end
        second = receive do value -> value end
        extra = receive do _value -> 1 after 0 -> 0 end
        {result, first, second, extra}
      end
    end
    """

    assert Batata.execute(source, ctx) == {2, 1, 2, 0}
  end

  test "emits a verified resumable native find loop", %{ctx: ctx} do
    source = """
    defmodule EnumFindIRFixture do
      def main(), do: Enum.find(1..5, &(rem(&1, 2) == 0))
    end
    """

    module = Batata.compile(source, ctx, reduction_budget: 1)
    assert MLIR.verify?(module)

    ir = MLIR.to_string(module, generic: true)
    assert ir =~ ~s{"ex.enumerable_to_list_range"}
    assert ir =~ ~s{"ex.apply"}
    assert ir =~ ~s{"scf.while"}
    assert ir =~ ~s{"ex.reduction_tick"}
  end

  test "resumes captured find under a one-reduction budget", %{ctx: ctx} do
    source = """
    defmodule EnumFindBudgetFixture do
      def main() do
        wanted = [:d]
        Enum.find([:a, :b, :c, :d], &(&1 in wanted))
      end
    end
    """

    assert Batata.execute(source, ctx, reduction_budget: 1) == :d
  end

  test "rejects predicates without a boolean result contract", %{ctx: ctx} do
    source = """
    defmodule EnumFindInvalidPredicateFixture do
      defp value(item), do: item
      def main(), do: Enum.find([1], &value/1)
    end
    """

    assert_raise Batata.Lift.Error, ~r/supported boolean local predicate/, fn ->
      Batata.execute(source, ctx)
    end
  end
end
