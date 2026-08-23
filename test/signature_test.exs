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
