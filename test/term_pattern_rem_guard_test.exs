defmodule Batata.TermPatternRemGuardTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Beaver.MLIR

  test "selects struct and map clauses with qualified and unqualified rem guards", %{ctx: ctx} do
    source = """
    defmodule TermPatternRemGuard do
      defstruct coef: 0

      defp classify(%__MODULE__{coef: coef}) when Kernel.rem(coef, 10) != 0, do: :nonzero
      defp classify(%__MODULE__{coef: coef}) when rem(coef, 10) == 0, do: :zero
      defp classify(_value), do: :other

      defp map_classify(%{coef: coef}) when rem(coef, 10) === 0, do: :zero
      defp map_classify(%{coef: coef}) when Kernel.rem(coef, 10) !== 0, do: :nonzero
      defp map_classify(_value), do: :other

      def main() do
        {
          classify(%__MODULE__{coef: 21}),
          classify(%__MODULE__{coef: 20}),
          classify(%__MODULE__{coef: :not_an_integer}),
          map_classify(%{coef: -20}),
          map_classify(%{coef: -21}),
          map_classify(%{coef: :not_an_integer})
        }
      end
    end
    """

    assert Batata.execute(source, ctx) == {:nonzero, :zero, :other, :zero, :nonzero, :other}

    rendered = source |> Batata.compile(ctx) |> MLIR.to_string(generic: true)
    assert rendered =~ ~s{"ex.rem"}
    assert rendered =~ ~s{"ex.is_integer"}
    assert rendered =~ ~s{"scf.if"}
  end

  test "turns zero divisors and out-of-scalar integers into guard failure", %{ctx: ctx} do
    source = """
    defmodule InvalidTermPatternRemGuard do
      defp zero_divisor(%{value: value}) when rem(value, 0) == 0, do: :selected
      defp zero_divisor(_value), do: :fallback

      defp oversized(%{value: value}) when rem(value, 10) == 0, do: :selected
      defp oversized(_value), do: :fallback

      def main() do
        {
          zero_divisor(%{value: 20}),
          oversized(%{value: 10_000_000_000_000_000_000_000_000_000_000_000_000})
        }
      end
    end
    """

    assert Batata.execute(source, ctx) == {:fallback, :fallback}
  end
end
