defmodule Batata.BigintArithmeticTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Beaver.MLIR

  @huge 10_000_000_000_000_000_000_000_000_000_000_000_001

  test "preserves boxed integers through arithmetic", %{ctx: ctx} do
    source = """
    defmodule BigintArithmeticFixture do
      def main() do
        value = #{@huge}
        negative = 0 - value
        {
          value + 1,
          value - 1,
          value * 10,
          div(negative, 10),
          rem(negative, 10),
          Kernel.abs(negative)
        }
      end
    end
    """

    assert Batata.execute(source, ctx) ==
             {@huge + 1, @huge - 1, @huge * 10, div(-@huge, 10), rem(-@huge, 10), @huge}

    rendered = source |> Batata.compile(ctx) |> MLIR.to_string(generic: true)
    assert rendered =~ "ex.integer_add"
    assert rendered =~ "ex.integer_sub"
    assert rendered =~ "ex.integer_mul"
    assert rendered =~ "ex.integer_div"
    assert rendered =~ "ex.integer_rem"
  end

  test "keeps recursive boxed division and multiplication as terms", %{ctx: ctx} do
    source = """
    defmodule BigintRecursiveArithmeticFixture do
      defp digits(0, length), do: length
      defp digits(value, length), do: digits(div(value, 10), length + 1)
      defp pad(value), do: value * 10

      def main(), do: {digits(#{@huge}, 0), pad(#{@huge})}
    end
    """

    assert Batata.execute(source, ctx) == {length(Integer.digits(@huge)), @huge * 10}
  end

  test "preserves term integer fields returned by tuple helpers", %{ctx: ctx} do
    source = """
    defmodule BigintTupleArithmeticFixture do
      defp pow10(0), do: 1
      defp pow10(exp), do: 10 * pow10(exp - 1)

      defp align(left, left_exp, right, right_exp) when left_exp == right_exp,
        do: {left, right}

      defp align(left, left_exp, right, right_exp) when left_exp > right_exp,
        do: {left * pow10(left_exp - right_exp), right}

      defp align(left, left_exp, right, right_exp),
        do: {left, right * pow10(right_exp - left_exp)}

      defp choose(2), do: 100
      defp choose(_), do: 1

      def main() do
        {left, right} = align(55, -1, 225, -2)
        {left - right, align(#{@huge}, 1, 1, 0), choose(#{@huge} - #{@huge} + 2)}
      end
    end
    """

    assert Batata.execute(source, ctx) == {325, {@huge * 10, 1}, 100}
  end

  test "preserves boxed coefficients destructured from structs", %{ctx: ctx} do
    source = """
    defmodule BigintStructArithmeticFixture do
      defstruct sign: 1, coef: 0, exp: 0

      defp add(%__MODULE__{coef: :nan} = left, %__MODULE__{}), do: left
      defp add(%__MODULE__{}, %__MODULE__{coef: :nan} = right), do: right

      defp add(
             %__MODULE__{coef: :infinity, sign: sign} = left,
             %__MODULE__{coef: :infinity, sign: sign} = right
           ) do
        if left.exp > right.exp, do: left, else: right
      end

      defp add(%__MODULE__{coef: :infinity}, %__MODULE__{coef: :infinity}),
        do: %__MODULE__{coef: :nan}

      defp add(%__MODULE__{coef: :infinity} = left, %__MODULE__{}), do: left
      defp add(%__MODULE__{}, %__MODULE__{coef: :infinity} = right), do: right

      defp add(%__MODULE__{} = left, %__MODULE__{} = right) do
        %__MODULE__{sign: sign1, coef: coef1} = left
        %__MODULE__{sign: sign2, coef: coef2} = right
        %__MODULE__{coef: Kernel.abs(sign1 * coef1 + sign2 * coef2)}
      end

      def main(), do: add(%__MODULE__{coef: #{@huge}}, %__MODULE__{coef: 10})
    end
    """

    assert Batata.execute(source, ctx) == %{
             __struct__: BigintStructArithmeticFixture,
             sign: 1,
             coef: @huge + 10,
             exp: 0
           }
  end

  test "preserves immediate integer roots returned by mixed term dispatch", %{ctx: ctx} do
    source = """
    defmodule ImmediateIntegerTermRootFixture do
      defp decode(<<>>), do: 20
      defp decode(_input), do: nil

      def main(), do: decode(<<>>)
    end
    """

    assert Batata.execute(source, ctx) == 20

    rendered = source |> Batata.compile(ctx) |> MLIR.to_string(generic: true)
    assert rendered =~ "ex.result_create_term"
  end
end
