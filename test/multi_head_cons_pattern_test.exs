defmodule Batata.MultiHeadConsPatternTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata

  @source """
  defmodule MultiHeadConsPatternKernel do
    def split([a, b | rest]) when is_integer(a) and is_integer(b) do
      {1, a, b, if(is_list(rest), do: 1, else: 0)}
    end

    def split(_other), do: {0, 0, 0, 0}

    def exact([a, b]), do: {1, a, b}
    def exact(_other), do: {0, 0, 0}

    def construct(tail), do: [1, 2 | tail]

    def inspect_constructed(tail) do
      [first, second | rest] = construct(tail)
      {first, second, rest}
    end

    def main() do
      {
        split([1, 2, 3, 4]),
        split([1 | [2 | 3]]),
        split([1]),
        split([1, "two", 3]),
        exact([1, 2]),
        exact([1, 2, 3]),
        exact([1 | [2 | 3]]),
        inspect_constructed([3, 4]),
        inspect_constructed(3)
      }
    end
  end
  """

  test "constructs and matches multi-head proper and improper cons spines with BEAM semantics", %{
    ctx: ctx
  } do
    assert beam_result(@source) == Batata.execute(@source, ctx)
  end

  test "lowers multi-head construction syntax without a synthetic local |/2 call", %{ctx: ctx} do
    ir = @source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)

    refute ir =~ "__batata_fn_7c_2"
    assert ir =~ "ex.list_cons"
  end

  defp beam_result(source) do
    [{module, _binary}] = Code.compile_string(source)

    try do
      module.main()
    after
      :code.purge(module)
      :code.delete(module)
    end
  end
end
