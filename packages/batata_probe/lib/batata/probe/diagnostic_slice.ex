defmodule Batata.Probe.DiagnosticSlice do
  @moduledoc false

  @ordinary_kinds [:def, :defp]
  @macro_kinds [:defmacro, :defmacrop]

  @type signature :: {atom(), non_neg_integer()}

  @doc false
  @spec ordinary_definitions([Macro.t()], MapSet.t(signature())) :: [Macro.t()]
  def ordinary_definitions(forms, compile_time_public \\ MapSet.new()) when is_list(forms) do
    compile_time_only = compile_time_only_signatures(forms, compile_time_public)

    Enum.filter(forms, fn form ->
      case definition(form) do
        [%{kind: kind, signature: signature}] when kind in @ordinary_kinds ->
          not MapSet.member?(compile_time_only, signature)

        _ ->
          false
      end
    end)
  end

  @doc false
  @spec compile_time_only_signatures([Macro.t()], MapSet.t(signature())) ::
          MapSet.t(signature())
  def compile_time_only_signatures(forms, compile_time_public \\ MapSet.new())
      when is_list(forms) do
    definitions = Enum.flat_map(forms, &definition/1)
    graph = call_graph(definitions)

    macro_roots = signatures(definitions, @macro_kinds)
    public = signatures(definitions, [:def])
    compile_time_public = MapSet.intersection(compile_time_public, public)

    compile_time_reachable =
      graph
      |> reachable(MapSet.union(macro_roots, compile_time_public))

    ordinary_roots =
      definitions
      |> signatures(@ordinary_kinds)
      |> MapSet.difference(compile_time_reachable)
      |> MapSet.union(MapSet.difference(public, compile_time_public))

    compile_time_reachable
    |> MapSet.difference(reachable(graph, ordinary_roots))
    |> MapSet.intersection(signatures(definitions, @ordinary_kinds))
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
        {:|>, _, [_left, {name, _, arguments}]} = node, calls
        when is_atom(name) and is_list(arguments) ->
          {node, MapSet.put(calls, {name, length(arguments) + 1})}

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
