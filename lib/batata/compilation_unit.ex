defmodule Batata.CompilationUnit do
  @moduledoc """
  Builds one collision-free frontend snapshot from a set of modules.

  Function identities are qualified by their defining module before lift.
  Local calls and calls to another module in the same unit are rewritten to
  those identities. Calls outside the unit remain remote calls and continue to
  be handled by the existing stdlib/runtime boundary.
  """

  alias Batata.Frontend

  @spec build([Frontend.Module.t()]) :: Frontend.Module.t()
  def build(modules) when is_list(modules) and modules != [] do
    modules = Enum.map(modules, &prune_unreachable_private_definitions/1)
    symbols = symbol_table(modules)

    definitions =
      Enum.flat_map(modules, fn module ->
        Enum.map(module.definitions, &qualify_definition(&1, module.name, symbols))
      end)

    %Frontend.Module{
      name: __MODULE__,
      definitions: definitions,
      struct_schemas: shared_schemas(modules)
    }
  end

  defp prune_unreachable_private_definitions(module) do
    grouped = Enum.group_by(module.definitions, &{&1.name, &1.arity})

    roots =
      grouped
      |> Enum.filter(fn {_signature, definitions} ->
        Enum.any?(definitions, &(&1.kind == :def))
      end)
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    reachable = reachable_signatures(roots, grouped, module.name)

    definitions =
      Enum.filter(module.definitions, fn definition ->
        MapSet.member?(reachable, {definition.name, definition.arity})
      end)

    %{module | definitions: definitions}
  end

  defp reachable_signatures(roots, grouped, module) do
    visit_signatures(MapSet.to_list(roots), roots, grouped, module)
  end

  defp visit_signatures([], reachable, _grouped, _module), do: reachable

  defp visit_signatures([signature | pending], reachable, grouped, module) do
    references =
      grouped
      |> Map.get(signature, [])
      |> Enum.flat_map(&definition_references(&1, grouped, module))
      |> MapSet.new()
      |> MapSet.difference(reachable)

    visit_signatures(
      pending ++ MapSet.to_list(references),
      MapSet.union(reachable, references),
      grouped,
      module
    )
  end

  defp definition_references(definition, grouped, module) do
    definition.clauses
    |> Enum.flat_map(fn clause ->
      [clause.patterns, clause.guard_ast, clause.body_ast]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&ast_references(&1, grouped, module))
    end)
  end

  defp ast_references(ast, grouped, module) do
    {_ast, references} =
      Macro.prewalk(ast, [], fn
        {:&, _, [{:/, _, [{name, _, _context}, arity]}]} = node, references
        when is_atom(name) and is_integer(arity) ->
          {node, maybe_reference(references, {name, arity}, grouped)}

        {:&, _, [{:/, _, [{{:., _, [module_ast, name]}, _, []}, arity]}]} = node, references
        when is_atom(name) and is_integer(arity) ->
          reference =
            if resolve_module(module_ast) == {:ok, module},
              do: maybe_reference(references, {name, arity}, grouped),
              else: references

          {node, reference}

        {name, _, arguments} = node, references
        when is_atom(name) and is_list(arguments) ->
          {node, maybe_reference(references, {name, length(arguments)}, grouped)}

        {{:., _, [module_ast, name]}, _, arguments} = node, references
        when is_atom(name) and is_list(arguments) ->
          reference =
            if resolve_module(module_ast) == {:ok, module},
              do: maybe_reference(references, {name, length(arguments)}, grouped),
              else: references

          {node, reference}

        node, references ->
          {node, references}
      end)

    references
  end

  defp maybe_reference(references, signature, grouped) do
    if Map.has_key?(grouped, signature), do: [signature | references], else: references
  end

  defp symbol_table(modules) do
    Map.new(
      for module <- modules,
          definition <- module.definitions do
        identity = {module.name, definition.name, definition.arity}
        {identity, qualified_name(identity)}
      end
    )
  end

  defp qualified_name(identity) do
    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16(case: :lower)

    String.to_atom("__batata_unit_" <> digest)
  end

  defp qualify_definition(definition, module, symbols) do
    qualified = Map.fetch!(symbols, {module, definition.name, definition.arity})

    clauses =
      Enum.map(definition.clauses, fn clause ->
        %{
          clause
          | patterns: rewrite_ast(clause.patterns, module, symbols),
            guard_ast: rewrite_ast(clause.guard_ast, module, symbols),
            body_ast: rewrite_ast(clause.body_ast, module, symbols)
        }
      end)

    %{definition | name: qualified, clauses: clauses}
  end

  defp rewrite_ast(nil, _module, _symbols), do: nil

  defp rewrite_ast(ast, module, symbols) do
    ast
    |> expand_pipes()
    |> Macro.prewalk(fn
      {:&, capture_metadata, [{:/, slash_metadata, [{name, call_metadata, context}, arity]}]} =
          capture
      when is_atom(name) and is_integer(arity) ->
        case Map.fetch(symbols, {module, name, arity}) do
          {:ok, qualified} ->
            {:&, capture_metadata,
             [{:/, slash_metadata, [{qualified, call_metadata, context}, arity]}]}

          :error ->
            capture
        end

      {:&, capture_metadata,
       [
         {:/, slash_metadata, [{{:., _, [module_ast, name]}, call_metadata, []}, arity]}
       ]} = capture
      when is_atom(name) and is_integer(arity) ->
        with {:ok, target_module} <- resolve_module(module_ast),
             {:ok, qualified} <- Map.fetch(symbols, {target_module, name, arity}) do
          {:&, capture_metadata, [{:/, slash_metadata, [{qualified, call_metadata, nil}, arity]}]}
        else
          _ -> capture
        end

      {name, metadata, arguments} = call when is_atom(name) and is_list(arguments) ->
        case Map.fetch(symbols, {module, name, length(arguments)}) do
          {:ok, qualified} -> {qualified, metadata, arguments}
          :error -> call
        end

      {{:., dot_metadata, [module_ast, name]}, call_metadata, arguments}
      when is_atom(name) and is_list(arguments) ->
        with {:ok, target_module} <- resolve_module(module_ast),
             {:ok, qualified} <- Map.fetch(symbols, {target_module, name, length(arguments)}) do
          {qualified, call_metadata, arguments}
        else
          _ -> {{:., dot_metadata, [module_ast, name]}, call_metadata, arguments}
        end

      node ->
        node
    end)
  end

  # Qualification must see a pipe call's effective arity. Leaving the pipe for
  # Lift would qualify `value |> local(opts)` as local/1, then insert `value`
  # and emit a local/2 call against the local/1 symbol. Post-order expansion
  # handles nested pipelines from the inside out before names are rewritten.
  defp expand_pipes(ast) do
    Macro.postwalk(ast, fn
      {:|>, _, [left, right]} -> Macro.pipe(left, right, 0)
      node -> node
    end)
  end

  defp resolve_module(module) when is_atom(module), do: {:ok, module}

  defp resolve_module({:__aliases__, _, parts}) when is_list(parts) and parts != [] do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  defp resolve_module(_ast), do: :error

  defp shared_schemas(modules) do
    Enum.reduce(modules, %{}, fn module, schemas ->
      schemas = Map.merge(schemas, module.struct_schemas || %{})

      if module.struct_schema,
        do: Map.put(schemas, module.name, module.struct_schema),
        else: schemas
    end)
  end
end
