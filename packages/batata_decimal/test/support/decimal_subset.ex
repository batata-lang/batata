defmodule Batata.Decimal.Test.Subset do
  @moduledoc false

  # These finite-number kernels preserve the arithmetic and guard shapes from
  # Decimal 2.3.0 while representing `%Decimal{sign, coef, exp}` as the tuple
  # `{sign, coefficient, scale}`, where `scale` is the negated exponent.
  # The tuple boundary isolates the compiler/runtime signal from the still
  # unsupported `defstruct` and struct-pattern frontend surface.
  def source(expression) do
    """
    defmodule DecimalSubset do
      def finite_mult(sign1, coef1, scale1, sign2, coef2, scale2) do
        sign = sign1 * sign2
        {sign, coef1 * coef2, scale1 + scale2}
      end
      def comparison_guard(coef, other, multiplier) do
        case {coef, other, multiplier} do
          {left, right, factor} when left >= 0 and left >= right * factor -> 1
          _ -> 0
        end
      end
      def positive_guard(exp) do
        case {exp, 0} do
          {value, _} when value > 0 -> 1
          _ -> 0
        end
      end
      def normalize(coef) do
        case {coef, 7} do
          {value, 7} when is_integer(value) ->
            {rem(value, 7), div(value, 7), value + 1}

          _ ->
            {0, 0, 0}
        end
      end
      def divisible_guard(coef) do
        case {coef, 10} do
          {value, 10} when is_integer(value) and rem(value, 10) == 0 -> 1
          _ -> 0
        end
      end
      def main(), do: (#{expression})
    end
    """
  end

  def new_guard_expression(sign, coef, exp) do
    """
    case {#{sign}, #{coef}, #{exp}} do
      {sign, coef, exp}
      when sign in [1, -1] and
             ((is_integer(coef) and coef >= 0) or coef in [:NaN, :inf]) and
             is_integer(exp) ->
        1

      _ ->
        0
    end
    """
  end
end
