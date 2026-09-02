defmodule Batata.UnaryIntegerOperatorTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata.{CompilationUnit, Frontend}

  test "executes dynamic unary integer operators and struct-field negation", %{ctx: ctx} do
    source = """
    defmodule UnaryIntegerOracle do
      defstruct sign: 1

      defp negate(value), do: -value
      defp positive(value), do: +value

      defp flip(%__MODULE__{sign: sign} = value) do
        %{value | sign: -sign}
      end

      def main() do
        {negate(7), negate(-9), positive(-4), flip(%__MODULE__{sign: -1}).sign}
      end
    end
    """

    assert Batata.execute(source, ctx) == {-7, 9, -4, 1}

    ir = source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)
    assert ir =~ ~s{"ex.sub"}
    refute ir =~ "__batata_fn_2d_1"
  end

  test "keeps non-integer unary operands behind the arithmetic boundary", %{ctx: ctx} do
    source = """
    defmodule InvalidUnaryIntegerOracle do
      defp negate(value), do: -value
      def main(), do: negate(:not_an_integer)
    end
    """

    assert_raise ArgumentError, "unary integer operators require scalar integer operands", fn ->
      Batata.execute(source, ctx)
    end
  end

  test "rejects dynamic boxed integers instead of truncating them", %{ctx: ctx} do
    source = """
    defmodule BoxedUnaryIntegerOracle do
      defp negate(value), do: -value
      def main(), do: negate(10_000_000_000_000_000_000_000_000_000_000_000_000)
    end
    """

    assert_raise ArgumentError, "unary integer operators require scalar integer operands", fn ->
      Batata.execute(source, ctx)
    end
  end

  test "fails closed instead of wrapping minimum i64 negation", %{ctx: ctx} do
    source = """
    defmodule MinimumUnaryIntegerOracle do
      defp negate(value), do: -value
      def main(), do: negate(-9_223_372_036_854_775_808)
    end
    """

    assert_raise SystemLimitError,
                 "unary negation exceeds the supported i64 scalar range",
                 fn -> Batata.execute(source, ctx) end
  end

  test "retains unary integer semantics through compilation-unit qualification", %{ctx: ctx} do
    sources = [
      """
      defmodule UnaryIntegerProvider do
        def negate(value), do: -value
      end
      """,
      """
      defmodule UnaryIntegerConsumer do
        def main(), do: UnaryIntegerProvider.negate(42)
      end
      """
    ]

    unit =
      sources
      |> Frontend.from_sources()
      |> CompilationUnit.build(entry: {UnaryIntegerConsumer, :main, 0})

    assert Batata.execute(unit, ctx) == -42
  end
end
