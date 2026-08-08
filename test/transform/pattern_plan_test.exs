defmodule Batata.Transform.PatternPlanTest do
  use ExUnit.Case, async: true

  alias Batata.Transform.PatternPlan
  alias Batata.Transform.PatternPlan.{ClausePlan, Step}

  defp plan!(source) do
    {:case, _, [scrutinee, [do: clauses]]} = Code.string_to_quoted!(source)
    PatternPlan.lower_case(scrutinee, clauses)
  end

  defp ops(steps), do: Enum.map(steps, & &1.op)

  test "lowers a tuple pattern into tuple and bind steps" do
    steps = PatternPlan.lower_pattern(Code.string_to_quoted!("{a, b}"))

    assert ops(steps) == [:tuple, :bind, :bind]
    assert [%Step{op: :tuple, path: [], value: 2}] = Enum.take(steps, 1)
    assert [%Step{op: :bind, path: [1], value: :b}] = Enum.drop(steps, 2)
  end

  test "lowers nested tuple patterns with paths" do
    steps = PatternPlan.lower_pattern(Code.string_to_quoted!("{a, {b, c}}"))

    assert ops(steps) == [:tuple, :bind, :tuple, :bind, :bind]
    assert [%Step{op: :tuple, path: [1], value: 2}] = Enum.drop(steps, 2) |> Enum.take(1)
    assert [%Step{op: :bind, path: [1, 0], value: :b}] = Enum.drop(steps, 3) |> Enum.take(1)
  end

  test "lowers exact list patterns" do
    steps = PatternPlan.lower_pattern(Code.string_to_quoted!("[1, x]"))

    assert ops(steps) == [:list_exact, :literal, :bind]
    assert [%Step{op: :list_exact, value: 2}] = Enum.take(steps, 1)
    assert [%Step{op: :literal, value: 1}] = Enum.drop(steps, 1) |> Enum.take(1)
  end

  test "lowers cons patterns into head/tail steps" do
    steps = PatternPlan.lower_pattern(Code.string_to_quoted!("[h | t]"))

    assert ops(steps) == [:list_cons, :list_head, :list_tail, :bind, :bind]
  end

  test "lowers literals, wildcards and binds" do
    assert [%Step{op: :literal, value: 42}] =
             PatternPlan.lower_pattern(Code.string_to_quoted!("42"))

    assert [%Step{op: :wildcard}] = PatternPlan.lower_pattern(Code.string_to_quoted!("_"))
    assert [%Step{op: :bind, value: :x}] = PatternPlan.lower_pattern(Code.string_to_quoted!("x"))
  end

  test "marks map and binary patterns unsupported" do
    assert [%Step{op: :unsupported}] =
             PatternPlan.lower_pattern(Code.string_to_quoted!("%{k => v}"))

    assert [%Step{op: :unsupported}] =
             PatternPlan.lower_pattern(Code.string_to_quoted!("<<h, t::binary>>"))
  end

  test "builds clause plans with vars and guard refinements" do
    plan =
      plan!("""
      case x do
        {a, b} when is_tuple(a) -> a
        _ -> 0
      end
      """)

    assert [%ClausePlan{vars: [:a, :b], refinements: [refinement]}, _] = plan.clauses
    assert refinement.var == :a
    assert refinement.predicate == :is_tuple
    assert refinement.type == :tuple
  end

  test "records literal patterns and bound vars per clause" do
    plan =
      plan!("""
      case x do
        [1, y] -> y
        _ -> 0
      end
      """)

    assert [%ClausePlan{vars: [:y]}, _] = plan.clauses

    assert [%Step{op: :literal, value: 1}] =
             plan.clauses |> hd() |> Map.fetch!(:steps) |> Enum.drop(1) |> Enum.take(1)
  end
end
