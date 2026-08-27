defmodule Batata.ScalarResultInferenceTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Beaver.MLIR

  @source """
  defmodule ScalarResultInferenceFixture do
    defp fail(value), do: throw({:bad, value})

    defp escapeu_last(value) do
      case value do
        0 -> 65
        1 -> 200
        _ -> fail(value)
      end
    end

    defp forwarded(value), do: escapeu_last(value)

    def main() do
      ascii = forwarded(0)
      wide = forwarded(1)

      {
        if(ascii <= 0x7F, do: ascii * 2, else: -1),
        if(wide <= 0x7F, do: -1, else: wide * 2)
      }
    end
  end
  """

  test "uses proven local scalar results in Jason-shaped comparisons and arithmetic", %{ctx: ctx} do
    expected = beam_result(@source)

    assert expected == {130, 400}
    assert Batata.execute(@source, ctx) == expected
  end

  test "emits verified scalar comparison and arithmetic IR", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    assert MLIR.verify?(module)
    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ ~s{predicate = "sle"}
    assert rendered =~ ~s{"ex.mul"}
  end

  test "keeps arbitrary term ordering rejected without a scalar-result proof", %{ctx: ctx} do
    source = """
    defmodule UnknownResultOrderingFixture do
      defp identity(value), do: value
      def main(), do: identity(:value) <= 127
    end
    """

    assert_raise Batata.Lift.Error, "ordering comparisons on terms are unsupported: :<=", fn ->
      Batata.compile(source, ctx)
    end
  end

  test "proves arithmetic helpers whose operands are scalar parameters", %{ctx: ctx} do
    source = """
    defmodule ParameterArithmeticFixture do
      defp add(left, right) when is_integer(left) and is_integer(right), do: left + right
      defp forwarded(left, right), do: add(left, right)
      def main(), do: forwarded(20, 22)
    end
    """

    assert Batata.execute(source, ctx) == 42
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
