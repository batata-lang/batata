defmodule Batata.ListWrapTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Beaver.MLIR

  @source """
  defmodule ListWrapFixture do
    defp wrap(value), do: List.wrap(value)

    defp inspect_wrapped_list(value) do
      [head | tail] = wrap(value)
      {head, tail}
    end

    def main() do
      {
        length(wrap(nil)),
        length(wrap([])),
        wrap([1, 2]),
        inspect_wrapped_list([1 | 2]),
        wrap(7),
        wrap(:signal),
        wrap({:ok, 1}),
        wrap(%{signal: :rounded}),
        wrap(<<1, 2>>)
      }
    end
  end
  """

  test "wraps dynamic terms with BEAM semantics", %{ctx: ctx} do
    expected =
      {0, 0, [1, 2], {1, 2}, [7], [:signal], [{:ok, 1}], [%{signal: :rounded}], [<<1, 2>>]}

    assert Batata.execute(@source, ctx) == expected
  end

  test "emits verified bounded branching and list construction", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)
    assert MLIR.verify?(module)

    ir = MLIR.to_string(module, generic: true)
    assert ir =~ ~s{"ex.is_list"}
    assert ir =~ ~s{"ex.term_eq"}
    assert length(Regex.scan(~r/"scf.if"/, ir)) == 2
    assert ir =~ ~s{"ex.list"}
  end

  test "declares pure constant-time conditional allocation" do
    assert Batata.Stdlib.metadata({List, :wrap, 1}) == %{
             purity: :pure,
             allocation: :may_allocate,
             preemption: :none,
             reductions: :constant
           }
  end
end
