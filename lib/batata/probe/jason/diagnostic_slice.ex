defmodule Batata.Probe.Jason.DiagnosticSlice do
  @moduledoc false

  @ordinary_kinds [:def, :defp]
  @macro_kinds [:defmacro, :defmacrop]

  @type signature :: {atom(), non_neg_integer()}

  @doc false
  @spec ordinary_definitions([Macro.t()]) :: [Macro.t()]
  def ordinary_definitions(forms) when is_list(forms) do
    definitions = Enum.flat_map(forms, &definition/1)
    graph = call_graph(definitions)

    macro_roots = signatures(definitions, @macro_kinds)
    macro_reachable = reachable(graph, macro_roots)

    ordinary_roots =
      definitions
      |> signatures(@ordinary_kinds)
      |> MapSet.difference(macro_reachable)
      |> MapSet.union(signatures(definitions, [:def]))

    macro_only =
      macro_reachable
      |> MapSet.difference(reachable(graph, ordinary_roots))

    Enum.filter(forms, fn form ->
      case definition(form) do
        [%{kind: :defp, signature: signature}] ->
          not MapSet.member?(macro_only, signature)

        [%{kind: kind}] when kind in @ordinary_kinds ->
          true

        _ ->
          false
      end
    end)
  end

  defp definition({kind, _, [head, [do: body]]})
       when kind in @ordinary_kinds or kind in @macro_kinds do
    case head_signature(head) do
      {:ok, signature} -> [%{kind: kind, signature: signature, body: body}]
      :error -> []
    end
  end

  defp definition(_form), do: []

  defp head_signature({:when, _, [head | _guards]}), do: head_signature(head)

  defp head_signature({name, _, arguments}) when is_atom(name) and is_list(arguments),
    do: {:ok, {name, length(arguments)}}

  defp head_signature(_head), do: :error

  defp signatures(definitions, kinds) do
    definitions
    |> Enum.filter(&(&1.kind in kinds))
    |> MapSet.new(& &1.signature)
  end

  defp call_graph(definitions) do
    known = MapSet.new(definitions, & &1.signature)

    Enum.reduce(definitions, %{}, fn definition, graph ->
      calls = MapSet.intersection(local_calls(definition.body), known)
      Map.update(graph, definition.signature, calls, &MapSet.union(&1, calls))
    end)
  end

  defp local_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:&, _, [{:/, _, [{name, _, context}, arity]}]} = node, calls
        when is_atom(name) and is_atom(context) and is_integer(arity) and arity >= 0 ->
          {node, MapSet.put(calls, {name, arity})}

        {name, _, arguments} = node, calls when is_atom(name) and is_list(arguments) ->
          {node, MapSet.put(calls, {name, length(arguments)})}

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp reachable(graph, roots) do
    visit(graph, MapSet.to_list(roots), MapSet.new())
  end

  defp visit(_graph, [], visited), do: visited

  defp visit(graph, [signature | pending], visited) do
    if MapSet.member?(visited, signature) do
      visit(graph, pending, visited)
    else
      callees = graph |> Map.get(signature, MapSet.new()) |> MapSet.to_list()
      visit(graph, callees ++ pending, MapSet.put(visited, signature))
    end
  end
end
