defmodule Batata.Test.DecimalSubset do
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
      def main(), do: #{expression}
    end
    """
  end
end
