defmodule Batata.ListsLastTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata.Stdlib

  test "returns the final term of a proper non-empty list", %{ctx: ctx} do
    source = """
    defmodule ListsLastOracle do
      def main() do
        {
          :lists.last([:only]),
          :lists.last([1, 2, :last]),
          :lists.last([:first, {:nested, [1, 2]}])
        }
      end
    end
    """

    expected = source |> Kernel.<>("\nListsLastOracle.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "resumes a budgeted traversal without losing the last element", %{ctx: ctx} do
    source = """
    defmodule BudgetedListsLast do
      def main(), do: :lists.last([1, 2, 3, 4, 5, {:last, 6}])
    end
    """

    for budget <- [1, 2] do
      assert Batata.execute(source, ctx, reduction_budget: budget) == {:last, 6}
    end
  end

  test "preserves :lists.last FunctionClauseError boundaries", %{ctx: ctx} do
    for {expression, arity} <- [
          {"[]", 1},
          {":not_a_list", 1},
          {"[1, 2 | :tail]", 2}
        ] do
      error =
        assert_raise FunctionClauseError, fn ->
          Batata.execute(
            """
            defmodule InvalidListsLast do
              def main(), do: :lists.last(#{expression})
            end
            """,
            ctx
          )
        end

      assert error.module == :lists
      assert error.function == :last
      assert error.arity == arity
    end
  end

  test "registers the traversal as raising, resumable, and per-element" do
    assert Stdlib.class({:lists, :last, 1}) == :native_term
    assert Stdlib.may_raise?({:lists, :last, 1})

    assert Stdlib.plan({:lists, :last, 1}) ==
             %Batata.Stdlib.Plan{
               mfa: {:lists, :last, 1},
               class: :native_term,
               purity: :pure,
               allocation: :none,
               preemption: :resumable,
               reductions: :per_element
             }
  end
end
