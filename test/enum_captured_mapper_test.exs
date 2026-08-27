defmodule Batata.EnumCapturedMapperTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata

  @source """
  defmodule EnumCapturedMapperKernel do
    def pair({item}, a, b, c, d) do
      _ = is_atom(a)
      _ = is_list(b)
      _ = is_tuple(c)
      _ = is_map(d)
      {item, {a, b, c, d}}
    end

    def main() do
      a = :alpha
      b = [:beta]
      c = {:gamma, 3}
      d = %{delta: 4}

      explicit = Enum.map([{1}, {2}], fn {item} -> {item, {a, b, c, d}} end)
      shorthand = [{3}, {4}] |> Enum.map(&pair(&1, a, b, c, d))
      {explicit, shorthand}
    end
  end
  """

  test "threads one to four tagged captures through compiled term mappers", %{ctx: ctx} do
    expected = beam_result(@source)
    assert expected == Batata.execute(@source, ctx)
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
