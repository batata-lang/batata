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
end
