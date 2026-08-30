defmodule Batata.SignatureTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend.{Clause, Definition}

  test "keeps arguments to remote native-term stdlib calls boxed" do
    value = Macro.var(:value, nil)
    definition = definition(:encode, value, quote(do: Date.to_iso8601(unquote(value))))

    assert Batata.Signature.infer([definition]) == %{{:encode, 1} => [:term]}
  end

  test "keeps variables embedded in map terms boxed" do
    value = Macro.var(:value, nil)
    definition = definition(:wrap, value, {:%{}, [], [value: value]})

    assert Batata.Signature.infer([definition]) == %{{:wrap, 1} => [:term]}
  end

  test "propagates a proved term ABI through direct local calls" do
    value = Macro.var(:value, nil)
    sink = definition(:sink, value, value)

    forward =
      definition(
        :forward,
        value,
        {:__block__, [], [{:length, [], [value]}, {:sink, [], [value]}]}
      )

    assert Batata.Signature.infer([sink, forward]) == %{
             {:forward, 1} => [:term],
             {:sink, 1} => [:term]
           }
  end

  test "propagates boxed integer literals through local calls" do
    value = Macro.var(:value, nil)
    classify = definition(:classify, value, :ok, {:>=, [], [value, 0]})
    huge = 10_000_000_000_000_000_000_000_000_000_000_000_000
    main = definition(:main, [], {:classify, [], [huge]})

    assert Batata.Signature.infer([classify, main]) == %{
             {:classify, 1} => [:term],
             {:main, 0} => []
           }
  end

  test "infers atom-context variables like source variables" do
    for context <- [nil, Batata.Frontend.DefaultArgExpand] do
      variable = {:value, [generated: context != nil], context}

      scalar = definition(:scalar, variable, {:+, [], [variable, 1]})
      term = definition(:term, variable, {:length, [], [variable]})

      assert Batata.Signature.infer([scalar]) == %{{:scalar, 1} => [:scalar]}
      assert Batata.Signature.infer([term]) == %{{:term, 1} => [:term]}
    end
  end

  test "infers a pinned map key and map scrutinee as terms" do
    map = {:map, [], nil}
    key = {:key, [], nil}
    pinned = {:%{}, [], [{{:^, [], [key]}, {:_, [], nil}}]}

    body =
      {:case, [],
       [map, [do: [{:->, [], [[pinned], :match]}, {:->, [], [[{:_, [], nil}], :missing]}]]]}

    lookup = definition(:lookup, [map, key], body)

    assert Batata.Signature.infer([lookup]) == %{{:lookup, 2} => [:term, :term]}
  end

  test "keeps binary_part indexes scalar" do
    binary = Macro.var(:binary, nil)
    start = Macro.var(:start, nil)
    length = Macro.var(:length, nil)

    slice =
      definition(:slice, [binary, start, length], {:binary_part, [], [binary, start, length]})

    assert Batata.Signature.infer([slice]) == %{
             {:slice, 3} => [:term, :scalar, :scalar]
           }
  end

  test "marks dynamic closure arguments as terms" do
    closure = {:closure, [], nil}
    value = {:value, [], nil}

    definition =
      definition(
        :apply_closure,
        [closure, value],
        {{:., [], [closure]}, [], [value]}
      )

    assert Batata.Signature.infer([definition]) == %{
             {:apply_closure, 2} => [:term, :term]
           }
  end

  test "uses the term ABI for integer literals in trailing patterns" do
    first = {:first, [], nil}
    second = {:second, [], nil}

    literal = definition(:dispatch, ["  ", 1], :one)
    fallback = definition(:dispatch, [first, second], {:{}, [], [first, second]})

    assert Batata.Signature.infer([literal, fallback]) == %{
             {:dispatch, 2} => [:term, :term]
           }
  end

  test "infers destructured tail parameters as terms without widening tuple scalars" do
    [original, skip, stack, decode, value] =
      Enum.map(~w(original skip stack decode value)a, &Macro.var(&1, nil))

    key = Macro.var(:key, nil)
    acc = Macro.var(:acc, nil)
    rest = Macro.var(:rest, nil)

    body =
      {:__block__, [],
       [
         {:=, [], [[key, {:|, [], [acc, rest]}], stack]},
         {:{}, [], [key, acc, rest, original, skip, decode, value]}
       ]}

    definition =
      definition(
        :object,
        [Macro.var(:tag, nil), original, skip, stack, decode, value],
        body
      )

    assert Batata.Signature.infer([definition]) == %{
             {:object, 6} => [:scalar, :scalar, :scalar, :term, :scalar, :scalar]
           }
  end

  test "infers direct, case, and transitive scalar results to a fixed point" do
    value = {:value, [], nil}

    literal = definition(:literal, [], 65)

    branching =
      definition(
        :branching,
        value,
        {:case, [],
         [
           value,
           [
             do: [
               {:->, [], [[0], 65]},
               {:->, [], [[{:_, [], nil}], {:fail, [], [value]}]}
             ]
           ]
         ]}
      )

    transitive = definition(:transitive, [], {:literal, [], []})
    mixed = definition(:mixed, [], {:if, [], [true, [do: 1, else: :term]]})
    recursive = definition(:recursive, [], {:recursive, [], []})

    assert Batata.Signature.infer_results(
             [transitive, recursive, mixed, branching, literal],
             MapSet.new([{:fail, 1}])
           ) == MapSet.new([{:branching, 1}, {:literal, 0}, {:transitive, 0}])
  end

  test "proves integer decoding only at explicit function boundaries" do
    value = {:value, [], nil}
    list = {:list, [], nil}
    index = {:index, [], nil}

    guarded =
      definition(
        :guarded,
        value,
        {:+, [], [value, 1]},
        {:is_integer, [], [value]}
      )

    identity = definition(:identity, value, value)

    list_at_zero = definition(:list_at, [{:|, [], [value, {:_, [], nil}]}, 0], value)

    list_at_tail =
      definition(
        :list_at,
        [{:|, [], [{:_, [], nil}, list]}, index],
        {:list_at, [], [list, {:-, [], [index, 1]}]},
        {:is_integer, [], [index]}
      )

    assert Batata.Signature.infer_integer_guards([
             guarded,
             identity,
             list_at_zero,
             list_at_tail
           ]) == %{
             {:guarded, 1} => [true],
             {:identity, 1} => [false],
             {:list_at, 2} => [false, true]
           }
  end

  defp definition(name, patterns, body) when is_list(patterns) do
    %Definition{
      kind: :defp,
      name: name,
      arity: length(patterns),
      clauses: [%Clause{patterns: patterns, body_ast: body}]
    }
  end

  defp definition(name, pattern, body) do
    definition(name, [pattern], body)
  end

  defp definition(name, patterns, body, guard) when is_list(patterns) do
    %Definition{
      kind: :defp,
      name: name,
      arity: length(patterns),
      clauses: [%Clause{patterns: patterns, guard_ast: guard, body_ast: body}]
    }
  end

  defp definition(name, pattern, body, guard) do
    %Definition{
      kind: :defp,
      name: name,
      arity: 1,
      clauses: [%Clause{patterns: [pattern], guard_ast: guard, body_ast: body}]
    }
  end
end
