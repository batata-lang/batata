defmodule Batata.NoReturnCaseTest do
  use Batata.Case, async: true, group: :execution_engine

  @source """
  defmodule NoReturnCaseFixture do
    defp fail(value), do: fail_inner(value)
    defp fail_inner(value), do: throw({:bad, value})

    defp choose(value) do
      case value do
        0 -> 42
        _ -> fail(value)
      end
    end

    def main(), do: choose(0)
  end
  """

  test "types a trailing no-return helper call from the live case clauses", %{ctx: ctx} do
    expected =
      @source |> Kernel.<>("\nNoReturnCaseFixture.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(@source, ctx) == expected
  end

  test "preserves the thrown fallback through a local helper chain", %{ctx: ctx} do
    source = """
    defmodule NoReturnCaughtFixture do
      defp fail(value), do: fail_inner(value)
      defp fail_inner(value), do: throw({:bad, value})

      defp choose(value) do
        case value do
          0 -> 42
          _ -> fail(value)
        end
      end

      def main() do
        try do
          choose(7)
        catch
          {:bad, _value} -> 17
        end
      end
    end
    """

    expected =
      source |> Kernel.<>("\nNoReturnCaughtFixture.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "keeps the throw path and its scalar result coercion explicit in IR", %{ctx: ctx} do
    ir = @source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)
    assert ir =~ ~s{"ex.throw"}
    assert ir =~ ~s{"ex.to_int"}
  end

  test "continues to reject an ordinary mixed scalar and term case", %{ctx: ctx} do
    source = """
    defmodule MixedCaseFixture do
      def main() do
        case 0 do
          0 -> 42
          _ -> :not_an_integer
        end
      end
    end
    """

    assert_raise Batata.Lift.Error, "case clauses must yield the same type", fn ->
      Batata.compile(source, ctx)
    end
  end
end
