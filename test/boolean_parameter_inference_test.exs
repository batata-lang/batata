defmodule Batata.BooleanParameterInferenceTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Batata.Lift
  alias Beaver.MLIR

  @source """
  defmodule BooleanParameterFixture do
    defp classify(exact, left, right) do
      if exact and left === right, do: :exact, else: :inexact
    end

    defp forwarded(flag, left, right), do: classify(flag, left, right)

    def main() do
      {
        forwarded(true, 10, 10),
        forwarded(1 === 2, 10, 10),
        classify(2 > 1, :same, :same)
      }
    end
  end
  """

  test "executes strict and through direct and forwarded boolean parameters", %{ctx: ctx} do
    assert Batata.execute(@source, ctx) == {:exact, :inexact, :exact}
  end

  test "verifies term boolean validation inside the actor boundary", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)
    rendered = MLIR.to_string(module, generic: true)

    assert MLIR.verify?(module)
    assert rendered =~ ~s/"ex.term_eq"/
    assert rendered =~ ~s/"ex.raise"/
  end

  test "keeps unknown and mixed private call sites fail closed", %{ctx: ctx} do
    sources = [
      """
      defmodule UnknownBooleanParameterFixture do
        defp strict(flag), do: flag and 1 === 1
        def main(value), do: strict(value)
      end
      """,
      """
      defmodule MixedBooleanParameterFixture do
        defp strict(flag), do: flag and 1 === 1
        def main(value), do: {strict(true), strict(value)}
      end
      """
    ]

    Enum.each(sources, fn source ->
      assert_raise Lift.Error,
                   ~r/body-level and requires compile-proven boolean scalar operands/,
                   fn -> Batata.execute(source, ctx, args: [:not_a_boolean]) end
    end)
  end

  test "does not infer externally callable boolean parameters", %{ctx: ctx} do
    source = """
    defmodule PublicBooleanParameterFixture do
      def main(flag), do: flag and 1 === 1
    end
    """

    assert_raise Lift.Error,
                 ~r/body-level and requires compile-proven boolean scalar operands/,
                 fn -> Batata.execute(source, ctx, args: [:not_a_boolean]) end
  end
end
