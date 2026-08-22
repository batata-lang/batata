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

  defp definition(name, pattern, body) do
    %Definition{
      kind: :defp,
      name: name,
      arity: 1,
      clauses: [%Clause{patterns: [pattern], body_ast: body}]
    }
  end
end
