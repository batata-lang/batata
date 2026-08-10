defmodule Batata.ReductionTickTest do
  use Batata.Case, async: true

  alias Batata

  @reduce_source """
  defmodule M do
    def main() do
      Enum.reduce([1, 2, 3], 0, fn x, a -> x + a end)
    end
  end
  """

  test "no budget: ex IR contains no reduction tick or clock op (#41 fast path)", %{ctx: ctx} do
    ir = Batata.compile(@reduce_source, ctx) |> Beaver.MLIR.to_string()

    refute ir =~ "ex.reduction_tick"
    refute ir =~ "ex.clock_init"
    refute ir =~ "ex.yield_mark"
  end

  test "budget: ex IR contains the reduction tick and clock init", %{ctx: ctx} do
    ir = Batata.compile(@reduce_source, ctx, reduction_budget: 2) |> Beaver.MLIR.to_string()

    assert ir =~ "ex.reduction_tick"
    assert ir =~ "ex.clock_init"
  end

  test "no budget: reduced LLVM IR has no clock runtime calls", %{ctx: ctx} do
    module =
      Batata.compile(@reduce_source, ctx)
      |> Batata.Lower.to_llvm(ctx, c_interface: true)

    ir = Beaver.MLIR.to_string(module)
    refute ir =~ "ex.term.clock_tick"
    refute ir =~ "ex.term.clock_init"
  end

  test "reduction_budget must be a positive integer when set", %{ctx: ctx} do
    for bad <- [0, -1, 2.5, "10"] do
      assert_raise ArgumentError, fn ->
        Batata.compile(@reduce_source, ctx, reduction_budget: bad)
      end
    end
  end

  test "batched and per-iteration modes agree on results", %{ctx: ctx} do
    source = """
    defmodule M do
      def main() do
        Enum.reduce([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0, fn x, a -> x + a end)
      end
    end
    """

    assert 55 == Batata.execute(source, ctx, reduction_budget: 3)
    assert 55 == Batata.execute(source, ctx, reduction_budget: 3, reduction_batching: false)
  end

  test "batched mode charges the whole budget in one tick; per-iteration charges one", %{
    ctx: ctx
  } do
    batched = Batata.compile(@reduce_source, ctx, reduction_budget: 3)
    assert Enum.uniq(tick_costs(batched)) == [3]

    per_iter =
      Batata.compile(@reduce_source, ctx, reduction_budget: 3, reduction_batching: false)

    assert Enum.uniq(tick_costs(per_iter)) == [1]
  end

  defp tick_costs(module) do
    module
    |> Beaver.Walker.postwalk([], fn
      %MLIR.Operation{} = op, acc ->
        if MLIR.Operation.name(op) == "ex.reduction_tick" do
          [cost] = op |> Beaver.Walker.operands() |> Enum.to_list()
          {:ok, owner} = MLIR.Value.owner(cost)
          attributes = owner |> Beaver.Walker.attributes() |> then(& &1[:value])

          {op,
           [
             attributes |> MLIR.CAPI.mlirIntegerAttrGetValueInt() |> Beaver.Native.to_term()
             | acc
           ]}
        else
          {op, acc}
        end

      element, acc ->
        {element, acc}
    end)
    |> elem(1)
  end
end
