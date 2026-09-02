defmodule Batata.ListConcatTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata.{CompilationUnit, Frontend, Stdlib}
  alias Beaver.MLIR

  test "copies the left spine and preserves an arbitrary right tail", %{ctx: ctx} do
    source = """
    defmodule ListConcatOracle do
      defp append(left, right), do: left ++ right

      def main() do
        improper = append([1, 2], :tail)

        {
          append([], :tail),
          append([1, 2], [3, 4]),
          :erlang.tl(:erlang.tl(improper)),
          append([1], [2]) ++ [3],
          Kernel.++([:qualified], [:call])
        }
      end
    end
    """

    expected = source |> Kernel.<>("\nListConcatOracle.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "rejects a non-list or improper left operand", %{ctx: ctx} do
    for expression <- [":not_a_list ++ []", "[1, 2 | :tail] ++ []"] do
      source = """
      defmodule InvalidListConcat do
        def main(), do: #{expression}
      end
      """

      assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
    end
  end

  test "resumes traversal without exposing or rebuilding a partial result", %{ctx: ctx} do
    source = """
    defmodule BudgetedListConcat do
      def main(), do: [1, 2, 3, 4, 5, 6] ++ [:done]
    end
    """

    for budget <- [1, 2] do
      assert Batata.execute(source, ctx, reduction_budget: budget) == [1, 2, 3, 4, 5, 6, :done]
    end
  end

  test "keeps ++ builtin through compilation-unit qualification", %{ctx: ctx} do
    sources = [
      """
      defmodule ListConcatProvider do
        def append(left, right), do: left ++ right
      end
      """,
      """
      defmodule ListConcatConsumer do
        def main(), do: ListConcatProvider.append([1, 2], [3])
      end
      """
    ]

    unit =
      sources
      |> Frontend.from_sources()
      |> CompilationUnit.build(entry: {ListConcatConsumer, :main, 0})

    assert Batata.execute(unit, ctx) == [1, 2, 3]

    rendered = unit |> Batata.compile(ctx) |> MLIR.to_string(generic: true)
    refute rendered =~ "__batata_fn_2b2b_2"
    assert length(Regex.scan(~r/"scf.while"/, rendered)) == 2
  end

  test "registers concatenation as raising, allocating, resumable, and per-element" do
    assert Batata.Signature.builtin_modes(Kernel, :++, 2) == [:term, :term]
    assert Stdlib.class({Kernel, :++, 2}) == :native_term
    assert Stdlib.may_raise?({Kernel, :++, 2})

    assert Stdlib.plan({Kernel, :++, 2}) ==
             %Stdlib.Plan{
               mfa: {Kernel, :++, 2},
               class: :native_term,
               purity: :pure,
               allocation: :may_allocate,
               preemption: :resumable,
               reductions: :per_element
             }
  end
end
