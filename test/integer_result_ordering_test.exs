defmodule Batata.IntegerResultOrderingTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Batata.Lift
  alias Beaver.MLIR

  @huge 10_000_000_000_000_000_000_000_000_000_000_000_000

  @source """
  defmodule IntegerResultOrderingFixture do
    defp boxed(), do: #{@huge}
    defp smaller(), do: #{@huge - 1}
    defp padded(value), do: value * 10
    defp forwarded(), do: boxed()

    def main() do
      left = smaller()
      right = forwarded()

      {
        left < right,
        right >= left,
        forwarded() > padded(2),
        padded(2) <= boxed()
      }
    end
  end
  """

  test "orders scalar and boxed local integer results exactly", %{ctx: ctx} do
    expressions = [
      "smaller() < boxed()",
      "boxed() >= smaller()",
      "forwarded() > padded(2)",
      "padded(2) <= forwarded()"
    ]

    Enum.each(expressions, fn expression ->
      assert Batata.execute(execution_source(expression), ctx) == :matched
    end)
  end

  test "uses integer_compare for term-ABI integer results", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    assert MLIR.verify?(module)
    assert module |> MLIR.to_string(generic: true) |> count_op("ex.integer_compare") == 4
  end

  test "validates dynamic arguments before integer-result ordering", %{ctx: ctx} do
    source = """
    defmodule DynamicIntegerResultOrderingFixture do
      defp increment(value), do: value + 1
      def main(), do: increment(:not_an_integer) < 2
    end
    """

    assert_raise ArgumentError, "integer arithmetic requires integer operands", fn ->
      Batata.execute(source, ctx)
    end
  end

  test "keeps unproven and mixed local results fail closed", %{ctx: ctx} do
    sources = [
      """
      defmodule UnknownIntegerResultOrderingFixture do
        defp identity(value), do: value
        def main(), do: identity(:value) < 1
      end
      """,
      """
      defmodule MixedIntegerResultOrderingFixture do
        defp mixed(0), do: 1
        defp mixed(_value), do: :value
        def main(), do: mixed(0) < 2
      end
      """
    ]

    Enum.each(sources, fn source ->
      assert_raise Lift.Error, "ordering comparisons on terms are unsupported: :<", fn ->
        Batata.compile(source, ctx)
      end
    end)
  end

  defp count_op(rendered, operation), do: length(Regex.scan(~r/"#{operation}"/, rendered))

  defp execution_source(expression) do
    """
    defmodule IntegerResultOrderingExecutionFixture do
      defp boxed(), do: #{@huge}
      defp smaller(), do: #{@huge - 1}
      defp padded(value), do: value * 10
      defp forwarded(), do: boxed()

      def main() do
        if #{expression}, do: :matched, else: :missed
      end
    end
    """
  end
end
