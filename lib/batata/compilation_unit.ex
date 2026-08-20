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
    Macro.prewalk(ast, fn
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

  defp resolve_module(module) when is_atom(module), do: {:ok, module}

  defp resolve_module({:__aliases__, _, parts}) when is_list(parts),
    do: {:ok, Module.concat(parts)}

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
