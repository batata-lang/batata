defmodule Batata.SignatureTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend.{Clause, Definition}

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

  test "uses the term ABI for integer literals in trailing patterns" do
    first = {:first, [], nil}
    second = {:second, [], nil}

    literal = definition(:dispatch, ["  ", 1], :one)
    fallback = definition(:dispatch, [first, second], {:{}, [], [first, second]})

    assert Batata.Signature.infer([literal, fallback]) == %{
             {:dispatch, 2} => [:term, :term]
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
end
