defmodule Batata.MultiHeadConsPatternTest do
  use Batata.Case, async: true

  alias Batata

  @source """
  defmodule MultiHeadConsPatternKernel do
    def split([a, b | rest]) when is_integer(a) and is_integer(b) do
      {1, a, b, if(is_list(rest), do: 1, else: 0)}
    end

    def split(_other), do: {0, 0, 0, 0}

    def exact([a, b]), do: {1, a, b}
    def exact(_other), do: {0, 0, 0}

    def main() do
      {
        split([1, 2, 3, 4]),
        split([1 | [2 | 3]]),
        split([1]),
        split([1, "two", 3]),
        exact([1, 2]),
        exact([1, 2, 3]),
        exact([1 | [2 | 3]])
      }
    end
  end
  """

  test "matches multi-head proper and improper cons spines with BEAM semantics", %{ctx: ctx} do
    assert beam_result(@source) == Batata.execute(@source, ctx)
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
