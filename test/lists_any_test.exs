defmodule Batata.ListsAnyTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Beaver.MLIR

  test "executes :lists.any/2 with local predicates and BEAM short-circuiting", %{ctx: ctx} do
    cases = [
      {"EmptyListsAny", ":lists.any(fn value -> value > 0 end, [])", false},
      {"FalseListsAny", ":lists.any(fn value -> value > 0 end, [-2, 0])", false},
      {"TrueListsAny", ":lists.any(fn value -> value > 0 end, [-2, 1, 0])", true},
      {"ImproperShortListsAny", ":lists.any(fn _value -> true end, [1 | :tail])", true}
    ]

    for {module, expression, expected} <- cases do
      source = """
      defmodule #{module} do
        def main(), do: #{expression}
      end
      """

      assert Batata.execute(source, ctx) == expected
    end
  end

  test "evaluates the list once and stops invoking the predicate after true", %{ctx: ctx} do
    source = """
    defmodule ShortCircuitListsAny do
      def tap(value) do
        send(self(), value)
        value + 0
      end

      def values() do
        send(self(), 9)
        [1, 2, 3]
      end

      def main() do
        result = :lists.any(fn value -> tap(value) == 2 end, values())
        evaluated = receive do value -> value end
        first = receive do value -> value end
        second = receive do value -> value end
        extra = receive do _value -> 1 after 0 -> 0 end
        {result, evaluated, first, second, extra}
      end
    end
    """

    assert Batata.execute(source, ctx) == {true, 9, 1, 2, 0}
  end

  test "resumes budgeted :lists.any/2 traversal", %{ctx: ctx} do
    source = """
    defmodule BudgetedListsAny do
      def match?(value), do: value == 5
      def main(), do: :lists.any(&match?/1, [1, 2, 3, 4, 5, 6])
    end
    """

    for budget <- [1, 2] do
      assert Batata.execute(source, ctx, reduction_budget: budget) == true
    end
  end

  test "supports captured anonymous predicates", %{ctx: ctx} do
    source = """
    defmodule CapturedListsAny do
      def main() do
        threshold = 2
        :lists.any(fn value -> value > threshold end, [1, 2, 3])
      end
    end
    """

    assert Batata.execute(source, ctx) == true
  end

  test "rejects invalid lists and unsupported predicates", %{ctx: ctx} do
    for list <- [":not_a_list", "[1 | :tail]"] do
      assert_raise ArgumentError, fn ->
        Batata.execute(
          """
          defmodule InvalidListsAnyList do
            def main(), do: :lists.any(fn _value -> false end, #{list})
          end
          """,
          ctx
        )
      end
    end

    for predicate <- [
          "predicate",
          "fn _value -> 1 end",
          "fn _left, _right -> false end",
          "&non_boolean/1"
        ] do
      source = """
      defmodule InvalidListsAnyPredicate do
        def main() do
          predicate = fn value -> value == 1 end
          :lists.any(#{predicate}, [1])
        end

        def non_boolean(_value), do: 1
      end
      """

      assert_raise Batata.Lift.Error, ~r/:lists.any\/2 requires/, fn ->
        Batata.compile(source, ctx)
      end
    end
  end

  test "lowers :lists.any/2 through the compiled closure and list cursor", %{ctx: ctx} do
    module =
      Batata.compile(
        """
        defmodule ListsAnyIR do
          def positive?(value), do: value > 0
          def main(), do: :lists.any(&positive?/1, [-1, 0, 1])
        end
        """,
        ctx
      )

    names = op_names(module)
    assert "ex.make_fun_with_signature" in names
    assert "ex.apply" in names
    assert "ex.list_head" in names
    assert "ex.list_tail" in names
    assert "scf.while" in names
  end

  defp op_names(module) do
    {_, operations} =
      Beaver.Walker.postwalk(module, [], fn
        %MLIR.Operation{} = operation, acc -> {operation, [operation | acc]}
        element, acc -> {element, acc}
      end)

    operations
    |> Enum.reverse()
    |> Enum.map(&MLIR.Operation.name/1)
  end
end
