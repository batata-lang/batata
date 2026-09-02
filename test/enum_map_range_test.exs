defmodule Batata.EnumMapRangeTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Beaver.MLIR

  @source """
  defmodule EnumMapRangeFixture do
    defp append_zeros(digits, exp, target_exp) do
      digits ++ Enum.map(1..(exp - target_exp), fn _ -> ?0 end)
    end

    def main() do
      {
        append_zeros([?1], 4, 1),
        Enum.map(1..3, fn item -> item end),
        Enum.map(3..1, fn item -> item + 10 end)
      }
    end
  end
  """

  test "maps ascending, descending, and dynamic-bound integer ranges", %{ctx: ctx} do
    assert Batata.execute(@source, ctx) == {[?1, ?0, ?0, ?0], [1, 2, 3], [13, 12, 11]}
  end

  test "materializes ranges before recognized Enum.map lowering", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)
    assert MLIR.verify?(module)

    ir = MLIR.to_string(module, generic: true)
    assert ir =~ ~s{"ex.enumerable_to_list_range"}
    refute ir =~ "__batata_fn_2e2e_2"
  end
end
