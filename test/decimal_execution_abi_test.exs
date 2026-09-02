defmodule Batata.DecimalExecutionAbiTest do
  use Batata.Case, async: true, group: :execution_engine

  test "returns a struct through Decimal-shaped context helpers", %{ctx: ctx} do
    source = """
    defmodule DecimalContextShape do
      defstruct sign: 1, coef: 0, exp: 0

      defp precision(num), do: {num, []}
      defp handle_error(result), do: {:ok, result}
      defp align(left, right), do: {left, right}

      defp context(num) do
        {result, _signals} = precision(num)

        case handle_error(result) do
          {:ok, result} -> result
          {:error, error} -> error
        end
      end

      def add(left, right) do
        {left, right} = align(left, right)
        context(%DecimalContextShape{coef: left + right})
      end

      def main(), do: add(12, 34)
    end
    """

    module = Batata.Frontend.from_source(source)
    scalar_results = Batata.Signature.infer_results(module.definitions)
    refute MapSet.member?(scalar_results, {:add, 2})
    refute MapSet.member?(scalar_results, {:context, 1})
    assert Batata.Signature.infer(module.definitions)[{:context, 1}] == [:term]
    assert Batata.Signature.infer(module.definitions)[{:handle_error, 1}] == [:term]

    assert Batata.execute(source, ctx) == %{
             __struct__: DecimalContextShape,
             sign: 1,
             coef: 46,
             exp: 0
           }
  end

  test "returns booleans through delegated comparison helpers", %{ctx: ctx} do
    source = """
    defmodule DecimalBooleanShape do
      defp compare(left, right), do: if(left == right, do: :eq, else: :lt)
      defp eq?(:nan, _right), do: false
      defp eq?(_left, :nan), do: false
      defp eq?(left, right), do: compare(left, right) == :eq
      def equal?(left, right), do: eq?(left, right)
      def main() do
        {
          if(equal?(10, 10), do: true, else: false),
          if(equal?(10, 11), do: true, else: false),
          if(equal?(:nan, 10), do: true, else: false)
        }
      end
    end
    """

    module = Batata.Frontend.from_source(source)
    boolean_results = Batata.Signature.infer_boolean_results(module.definitions)
    assert MapSet.member?(boolean_results, {:eq?, 2})
    assert MapSet.member?(boolean_results, {:equal?, 2})

    assert Batata.execute(source, ctx) == {true, false, false}
  end

  test "boxes scalar integers without retagging atom list elements", %{ctx: ctx} do
    source = """
    defmodule ListElementAbiShape do
      defp prepend(value, tail) when is_integer(value), do: [value | tail]
      def main(), do: {prepend(49, []), [true, nil]}
    end
    """

    assert Batata.execute(source, ctx) == {[49], [true, nil]}
  end
end
