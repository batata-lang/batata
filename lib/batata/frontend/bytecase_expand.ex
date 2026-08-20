defmodule Batata.Frontend.BytecaseExpand do
  @moduledoc """
  Discovers and expands bounded range-based binary dispatch macros.

  Discovery is structural across a source set. Provider modules are never
  loaded and macro bodies are never executed on the host.
  """

  alias Batata.Frontend.Literal

  @type signature :: {atom(), 2 | 3}
  @type registry :: %{optional(module()) => MapSet.t(signature())}

  @doc "Discovers public binary-dispatch macros in parsed source strings."
  @spec discover([String.t()]) :: registry()
  def discover(sources) when is_list(sources) do
    Enum.reduce(sources, %{}, fn source, registry ->
      source
      |> Code.string_to_quoted!()
      |> discover_ast(registry)
    end)
  end

  @doc "Removes discovered declarations/imports and expands their local calls."
  @spec expand(Macro.t(), registry()) :: Macro.t()
  def expand({:defmodule, metadata, [module_ast, [do: body]]}, registry) do
    module = literal_module(module_ast)
    declared = Map.get(registry, module, MapSet.new())

    {forms, _imports} =
      body
      |> body_forms()
      |> Enum.map_reduce(%{}, &expand_form(&1, &2, declared, registry))

    {:defmodule, metadata, [module_ast, [do: block(Enum.reject(forms, &is_nil/1))]]}
  end

  def expand(ast, _registry), do: ast

  defp discover_ast({:__block__, _, forms}, registry),
    do: Enum.reduce(forms, registry, &discover_ast/2)

  defp discover_ast({:defmodule, _, [module_ast, [do: body]]}, registry) do
    module = literal_module(module_ast)

    signatures =
      body
      |> body_forms()
      |> Enum.reduce(MapSet.new(), fn form, acc ->
        case dispatch_macro_signature(form) do
          {:ok, signature} -> MapSet.put(acc, signature)
          :error -> acc
        end
      end)

    if module != nil and MapSet.size(signatures) > 0,
      do: Map.put(registry, module, signatures),
      else: registry
  end

  defp discover_ast(_ast, registry), do: registry

  defp dispatch_macro_signature({:defmacro, _, [head, [do: body]]}) do
    with {:ok, {name, arity}} when arity in [2, 3] <- definition_signature(head),
         true <- dispatch_macro_body?(body) do
      {:ok, {name, arity}}
    else
      _ -> :error
    end
  end

  defp dispatch_macro_signature(_form), do: :error

  defp dispatch_macro_body?(body) do
    local_calls =
      Macro.prewalk(body, MapSet.new(), fn
        {name, _, arguments} = call, calls when is_atom(name) and is_list(arguments) ->
          {call, MapSet.put(calls, name)}

        node, calls ->
          {node, calls}
      end)
      |> elem(1)

    MapSet.member?(local_calls, :clauses_to_ranges) and
      MapSet.member?(local_calls, :jump_table) and
      MapSet.member?(local_calls, :jump_table_to_clauses)
  end

  defp expand_form(form, imports, declared, registry) do
    case macro_definition_signature(form) do
      {:ok, signature} ->
        if MapSet.member?(declared, signature), do: {nil, imports}, else: {form, imports}

      :error ->
        expand_non_definition(form, imports, registry)
    end
  end

  defp expand_non_definition({:import, _, _} = form, imports, registry) do
    case selected_imports(form, registry) do
      {:ok, module, signatures} ->
        imported = Enum.reduce(signatures, imports, &Map.put(&2, &1, module))
        {nil, imported}

      :error ->
        {form, imports}
    end
  end

  defp expand_non_definition({kind, metadata, [head, [do: body]]}, imports, _registry)
       when kind in [:def, :defp] do
    body = rewrite_calls(body, imports)
    {{kind, metadata, [head, [do: body]]}, imports}
  end

  defp expand_non_definition(form, imports, _registry), do: {form, imports}

  defp selected_imports({:import, _, [module_ast, options]}, registry)
       when is_list(options) do
    with module when is_atom(module) <- literal_module(module_ast),
         available when map_size(registry) > 0 <- Map.get(registry, module, MapSet.new()),
         requested when is_list(requested) <- Keyword.get(options, :only),
         signatures <- MapSet.new(requested),
         true <- MapSet.size(signatures) > 0 and MapSet.subset?(signatures, available) do
      {:ok, module, signatures}
    else
      _ -> :error
    end
  end

  defp selected_imports(_form, _registry), do: :error

  defp rewrite_calls(ast, imports) do
    Macro.postwalk(ast, fn
      {name, _, arguments} = call when is_atom(name) and is_list(arguments) ->
        signature = {name, length(arguments)}

        if Map.has_key?(imports, signature),
          do: expand_dispatch_call(call),
          else: call

      node ->
        node
    end)
  end

  defp expand_dispatch_call({name, metadata, [data, [do: clauses]]}) when is_list(clauses),
    do: build_case(name, metadata, data, clauses, nil)

  defp expand_dispatch_call({name, metadata, [data, maximum, [do: clauses]]})
       when is_list(clauses),
       do: build_case(name, metadata, data, clauses, maximum)

  defp expand_dispatch_call(call), do: call

  defp build_case(_name, metadata, data, clauses, explicit_maximum) do
    case split_clauses(clauses, explicit_maximum) do
      {:ok, range_clauses, default_clause, literal_clauses, maximum} ->
        expanded =
          Enum.map(range_clauses, &expand_range_clause/1) ++
            [expand_default_clause(default_clause, maximum)] ++ literal_clauses

        {:case, metadata, [data, [do: expanded]]}

      _ ->
        {:__batata_unsupported_bytecase__, metadata, [data, [do: clauses]]}
    end
  end

  defp split_clauses(clauses, explicit_maximum) do
    {range_clauses, tail} = Enum.split_while(clauses, &range_clause?/1)

    with [default_clause | literal_clauses] <- tail,
         true <- default_clause?(default_clause),
         {:ok, maximum} <- dispatch_maximum(range_clauses, explicit_maximum) do
      {:ok, range_clauses, default_clause, literal_clauses, maximum}
    else
      _ -> :error
    end
  end

  defp range_clause?({:->, _, [[{:in, _, [_byte, _range]}, _rest], _action]}), do: true
  defp range_clause?(_clause), do: false

  defp default_clause?({:->, _, [[_byte, _rest], _action]}), do: true
  defp default_clause?(_clause), do: false

  defp dispatch_maximum(_range_clauses, explicit) when is_integer(explicit) and explicit > 0,
    do: {:ok, explicit - 1}

  defp dispatch_maximum(range_clauses, nil) do
    range_clauses
    |> Enum.flat_map(fn {:->, _, [[{:in, _, [_byte, range]}, _rest], _action]} ->
      case eval_range(range) do
        {:ok, values} -> values
        :error -> []
      end
    end)
    |> case do
      [] -> :error
      values -> {:ok, Enum.max(values)}
    end
  end

  defp dispatch_maximum(_range_clauses, _explicit), do: :error

  defp expand_range_clause({:->, metadata, [[{:in, in_meta, [byte, range]}, rest], action]}) do
    byte = dispatch_byte(byte, metadata)
    pattern = binary_pattern(byte, rest, metadata)
    range = unwrap_unquote(range)
    guard = {:in, in_meta, [byte, range]}
    {:->, metadata, [[{:when, metadata, [pattern, guard]}], action]}
  end

  defp expand_default_clause({:->, metadata, [[byte, rest], action]}, maximum) do
    byte = dispatch_byte(byte, metadata)
    pattern = binary_pattern(byte, rest, metadata)
    guard = {:<=, metadata, [byte, maximum]}
    {:->, metadata, [[{:when, metadata, [pattern, guard]}], action]}
  end

  defp dispatch_byte({:_, _, nil}, metadata),
    do: {:__batata_dispatch_byte__, Keyword.put(metadata, :generated, true), nil}

  defp dispatch_byte(byte, _metadata), do: byte

  defp binary_pattern(byte, rest, metadata) do
    {:<<>>, metadata, [byte, {:"::", metadata, [rest, {:binary, metadata, nil}]}]}
  end

  defp unwrap_unquote({:unquote, _, [value]}), do: value
  defp unwrap_unquote(value), do: value

  defp eval_range({:unquote, _, [value]}), do: eval_range(value)

  defp eval_range({:sigil_c, _, [{:<<>>, _, [contents]}, []]}) when is_binary(contents),
    do: {:ok, String.to_charlist(contents)}

  defp eval_range(ast) do
    case Literal.eval(ast) do
      {:ok, %Range{} = range} -> {:ok, Enum.to_list(range)}
      {:ok, values} when is_list(values) -> {:ok, values}
      _ -> :error
    end
  end

  defp macro_definition_signature({:defmacro, _, [head, [do: _body]]}),
    do: definition_signature(head)

  defp macro_definition_signature(_form), do: :error

  defp definition_signature({name, _, arguments}) when is_atom(name) and is_list(arguments),
    do: {:ok, {name, length(arguments)}}

  defp definition_signature(_head), do: :error

  defp literal_module(ast) do
    case Literal.eval(ast) do
      {:ok, module} when is_atom(module) -> module
      _ -> nil
    end
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block([form]), do: form
  defp block(forms), do: {:__block__, [], forms}
end
