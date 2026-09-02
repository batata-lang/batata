defmodule Batata.CompilationUnit do
  @moduledoc """
  Builds one collision-free frontend snapshot from a set of modules.

  Function identities are qualified by their defining module before lift.
  Local calls and calls to another module in the same unit are rewritten to
  those identities. Calls outside the unit remain remote calls and continue to
  be handled by the existing stdlib/runtime boundary.

  Pass `entry: {module, function, arity}` to retain one qualified definition as
  `main`, allowing a multi-module unit to be exercised through the normal JIT
  entry boundary.
  """

  alias Batata.Frontend

  @builtin_protocol_targets %{
    Atom => :is_atom,
    BitString => :is_binary,
    Float => :is_float,
    Integer => :is_integer,
    List => :is_list,
    Map => :is_map,
    Tuple => :is_tuple
  }
  @unsupported_builtin_protocol_targets MapSet.new([Function, PID, Port, Reference])

  @spec build([Frontend.Module.t()], keyword()) :: Frontend.Module.t()
  def build(modules, opts \\ []) when is_list(modules) and modules != [] do
    modules = Enum.map(modules, &prune_unreachable_private_definitions/1)
    modules = expand_protocol_dispatchers(modules)
    symbols = symbol_table(modules, opts[:entry])

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

  defp expand_protocol_dispatchers(modules) do
    implementations =
      modules
      |> Enum.reject(&is_nil(&1.protocol_target))
      |> Enum.group_by(& &1.protocol)

    Enum.map(modules, fn module ->
      if module.protocol == module.name and is_nil(module.protocol_target) do
        impls = Map.get(implementations, module.name, [])
        validate_protocol_targets!(module.name, impls)

        definitions =
          Enum.map(module.definitions, &expand_protocol_definition(&1, module, impls))

        %{module | definitions: definitions}
      else
        module
      end
    end)
  end

  defp expand_protocol_definition(definition, protocol, implementations) do
    clauses =
      Enum.map(definition.clauses, fn clause ->
        case clause.body_ast do
          {:__protocol_dispatch__, _, [name, function, arity]}
          when name == protocol.name and function == definition.name and
                 arity == definition.arity ->
            %{
              clause
              | body_ast: protocol_dispatch_ast(protocol, definition, clause, implementations)
            }

          _other ->
            clause
        end
      end)

    %{definition | clauses: clauses}
  end

  defp protocol_dispatch_ast(protocol, definition, clause, implementations) do
    [value | _] = clause.patterns
    by_target = Map.new(implementations, &{&1.protocol_target, &1})
    fallback = protocol_fallback_ast(protocol, definition, clause, by_target)

    struct_clauses =
      implementations
      |> Enum.reject(&builtin_protocol_target?/1)
      |> Enum.sort_by(&inspect(&1.protocol_target))
      |> Enum.map(fn implementation ->
        pattern = {:%{}, [], [{:__struct__, implementation.protocol_target}]}
        {:->, [], [[pattern], protocol_impl_call(implementation, definition, clause.patterns)]}
      end)

    builtin_clauses =
      @builtin_protocol_targets
      |> Enum.sort_by(fn {target, _guard} -> inspect(target) end)
      |> Enum.flat_map(fn {target, guard} ->
        case Map.fetch(by_target, target) do
          {:ok, implementation} ->
            guarded = {:when, [], [{:_, [], nil}, {guard, [], [value]}]}

            [
              {:->, [],
               [[guarded], protocol_impl_call(implementation, definition, clause.patterns)]}
            ]

          :error ->
            []
        end
      end)

    # A map carrying __struct__ must never fall through to the Map
    # implementation. BEAM protocol dispatch first tries the struct module and
    # then the protocol fallback, while plain maps use the Map implementation.
    unknown_struct = {:%{}, [], [{:__struct__, {:_, [], nil}}]}

    {:case, [],
     [
       value,
       [
         do:
           struct_clauses ++
             [{:->, [], [[unknown_struct], fallback]}] ++
             builtin_clauses ++ [{:->, [], [[{:_, [], nil}], fallback]}]
       ]
     ]}
  end

  defp protocol_fallback_ast(protocol, definition, clause, implementations) do
    if protocol.protocol_options[:fallback_to_any] == true and
         Map.has_key?(implementations, Any) do
      implementations
      |> Map.fetch!(Any)
      |> protocol_impl_call(definition, clause.patterns)
    else
      [value | _] = clause.patterns

      {:__batata_raise__, [],
       [
         10,
         {:{}, [],
          [
            protocol.name,
            value,
            "protocol #{inspect(protocol.name)} is not implemented for value"
          ]}
       ]}
    end
  end

  defp protocol_impl_call(implementation, definition, arguments) do
    arguments =
      case {implementation.protocol_target, arguments} do
        {Integer, [value | rest]} -> [{:__batata_protocol_integer__, [], [value]} | rest]
        _other -> arguments
      end

    {{:., [], [implementation.name, definition.name]}, [], arguments}
  end

  defp builtin_protocol_target?(module) do
    Map.has_key?(@builtin_protocol_targets, module.protocol_target) or
      module.protocol_target == Any or
      MapSet.member?(@unsupported_builtin_protocol_targets, module.protocol_target)
  end

  defp validate_protocol_targets!(protocol, implementations) do
    duplicate_target =
      implementations
      |> Enum.frequencies_by(& &1.protocol_target)
      |> Enum.find(fn {_target, count} -> count > 1 end)

    unsupported =
      Enum.find(implementations, fn implementation ->
        MapSet.member?(@unsupported_builtin_protocol_targets, implementation.protocol_target)
      end)

    case {duplicate_target, unsupported} do
      {{target, _count}, _unsupported} ->
        raise ArgumentError,
              "protocol #{inspect(protocol)} has duplicate implementation target #{inspect(target)}"

      {nil, nil} ->
        :ok

      {nil, implementation} ->
        raise ArgumentError,
              "protocol #{inspect(protocol)} implementation target " <>
                "#{inspect(implementation.protocol_target)} requires an unsupported runtime predicate"
    end
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

  defp symbol_table(modules, entry) do
    symbols =
      Map.new(
        for module <- modules,
            definition <- module.definitions do
          identity = {module.name, definition.name, definition.arity}
          {identity, qualified_name(identity)}
        end
      )

    case entry do
      nil ->
        symbols

      {module, name, arity} = identity
      when is_atom(module) and is_atom(name) and is_integer(arity) and arity >= 0 ->
        if Map.has_key?(symbols, identity) do
          Map.put(symbols, identity, :main)
        else
          raise ArgumentError, "compilation unit entry is not defined: #{inspect(identity)}"
        end

      other ->
        raise ArgumentError,
              "compilation unit entry must be a {module, function, arity} tuple, got: " <>
                inspect(other)
    end
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

      {:++, _, [_left, _right]} = call ->
        call

      {name, metadata, arguments} = call when is_atom(name) and is_list(arguments) ->
        case Map.fetch(symbols, {module, name, length(arguments)}) do
          {:ok, qualified} -> {qualified, metadata, arguments}
          :error -> call
        end

      {{:., _dot_metadata, [Exception, :message]}, metadata, [exception]} ->
        exception_message_dispatch(exception, metadata, symbols)

      {{:., _dot_metadata, [{:__aliases__, _, [:Exception]}, :message]}, metadata, [exception]} ->
        exception_message_dispatch(exception, metadata, symbols)

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

  defp exception_message_dispatch(exception, metadata, symbols) do
    bound = Macro.var(:__batata_exception, __MODULE__)

    source_clauses =
      symbols
      |> Enum.flat_map(fn
        {{exception_module, :message, 1}, qualified} when exception_module != Exception ->
          pattern = {:%{}, [], [__struct__: exception_module]}
          [{:->, metadata, [[{:=, [], [pattern, bound]}], {qualified, metadata, [bound]}]}]

        _other ->
          []
      end)
      |> Enum.sort_by(fn {:->, _, [[{:=, _, [{:%{}, _, fields}, _]}], _]} ->
        fields |> Keyword.fetch!(:__struct__) |> inspect()
      end)

    protocol_pattern =
      {:=, [], [{:%{}, [], [__struct__: Protocol.UndefinedError]}, bound]}

    fallback = Macro.var(:__batata_unsupported_exception, __MODULE__)

    {:case, metadata,
     [
       exception,
       [
         do:
           source_clauses ++
             [
               {:->, metadata,
                [[protocol_pattern], {:__batata_protocol_undefined_message__, metadata, [bound]}]},
               {:->, metadata,
                [[fallback], {:__batata_unsupported_exception_message__, metadata, [fallback]}]}
             ]
       ]
     ]}
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
