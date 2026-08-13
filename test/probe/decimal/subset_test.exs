defmodule Batata.Probe.Decimal.SubsetTest do
  @moduledoc """
  Executable finite-number kernels derived from Decimal 2.3.0.

  The upstream struct is normalized to `{sign, coefficient, scale}` so the
  gate exercises Decimal's finite multiplication without claiming support for
  its compile-time `defstruct` surface. The capability manifest records the
  normalization and term-field guard failures found by the wider probe.
  """

  use Batata.Case, async: true

  alias Batata
  alias Batata.Test.DecimalSubset

  @cases [
    {"multiplies finite coefficients", "finite_mult(1, 125, 2, 0 - 1, 20, 1)"},
    {"preserves a positive sign", "finite_mult(1, 7, 0, 1, 9, 4)"},
    {"preserves a zero coefficient", "finite_mult(0 - 1, 0, 3, 1, 99, 2)"},
    {"accepts an equal scaled coefficient", "comparison_guard(100, 10, 10)"},
    {"rejects a negative coefficient", "comparison_guard(0 - 1, 0 - 1, 1)"},
    {"rejects a smaller scaled coefficient", "comparison_guard(99, 10, 10)"},
    {"accepts a positive exponent", "positive_guard(1)"},
    {"rejects a zero exponent", "positive_guard(0)"},
    {"normalizes a positive coefficient", "normalize(100)"},
    {"normalizes a negative coefficient", "normalize(0 - 15)"},
    {"normalizes a zero coefficient", "normalize(0)"},
    {"accepts a divisible coefficient", "divisible_guard(100)"},
    {"accepts a negative divisible coefficient", "divisible_guard(0 - 20)"},
    {"rejects a non-divisible coefficient", "divisible_guard(105)"},
    {"rejects a non-integer coefficient", "divisible_guard(false)"},
    {"accepts a finite new guard", DecimalSubset.new_guard_expression("1", "42", "0")},
    {"accepts a NaN new guard", DecimalSubset.new_guard_expression("0 - 1", ":NaN", "3")},
    {"accepts an infinity new guard", DecimalSubset.new_guard_expression("1", ":inf", "0 - 2")},
    {"rejects a negative finite coefficient",
     DecimalSubset.new_guard_expression("1", "0 - 1", "0")},
    {"rejects an unknown atom coefficient",
     DecimalSubset.new_guard_expression("1", ":other", "0")},
    {"rejects an invalid sign", DecimalSubset.new_guard_expression("0", "10", "0")},
    {"rejects a non-integer exponent", DecimalSubset.new_guard_expression("1", "10", "false")}
  ]

  for {name, expression} <- @cases do
    test name, %{ctx: ctx} do
      source = DecimalSubset.source(unquote(expression))

      assert beam_result(source) == Batata.execute(source, ctx)
    end
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
