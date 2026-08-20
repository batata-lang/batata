defmodule Batata.Frontend.MetadataMacroExpand do
  @moduledoc """
  Discovers and consumes macros whose only possible output is ignored metadata.

  Discovery is structural across one source set. No macro is loaded or
  executed, and calls are removed only after a matching lexical import.
  """

  alias Batata.Frontend.Literal

  @metadata_attributes [
    :behaviour,
    :compile,
    :deprecated,
    :dialyzer,
    :doc,
    :impl,
    :moduledoc,
    :opaque,
    :spec,
    :type,
    :typedoc,
    :typep
  ]

  @type signature :: {atom(), non_neg_integer()}
  @type registry :: %{optional(module()) => MapSet.t(signature())}

  @doc "Discovers metadata-only public macros in a set of parsed source strings."
  @spec discover([String.t()]) :: registry()
  def discover(sources) when is_list(sources) do
    Enum.reduce(sources, %{}, fn source, registry ->
      {:ok, ast} = Code.string_to_quoted(source)
      discover_ast(ast, registry)
    end)
  end

  @doc "Consumes discovered declarations, imports, and calls in one module."
  @spec expand(Macro.t(), registry()) :: Macro.t()
  def expand({:defmodule, metadata, [name_ast, [do: body]]}, registry) do
    module = module_name(name_ast)
    declared = Map.get(registry, module, MapSet.new())

    {forms, _imports} =
      body
      |> body_forms()
      |> Enum.map_reduce(MapSet.new(), &expand_form(&1, &2, declared, registry))

    {:defmodule, metadata, [name_ast, [do: block(forms)]]}
  end

  def expand(ast, _registry), do: ast

  defp discover_ast({:__block__, _, forms}, registry) do
    Enum.reduce(forms, registry, &discover_ast/2)
  end

  defp discover_ast({:defmodule, _, [name_ast, [do: body]]}, registry) do
    module = module_name(name_ast)

    signatures =
      body
      |> body_forms()
      |> Enum.reduce(MapSet.new(), fn form, signatures ->
        case metadata_macro_signature(form) do
          {:ok, signature} -> MapSet.put(signatures, signature)
          :error -> signatures
        end
      end)

    if module != nil and MapSet.size(signatures) > 0 do
      Map.update(registry, module, signatures, &MapSet.union(&1, signatures))
    else
      registry
    end
  end

  defp discover_ast(_ast, registry), do: registry

  defp expand_form(form, imports, declared, registry) do
    case macro_definition_signature(form) do
      {:ok, signature} ->
        if MapSet.member?(declared, signature), do: {nil, imports}, else: {form, imports}

      :error ->
        expand_non_definition(form, imports, registry)
    end
  end

  defp expand_non_definition({:import, _, _} = form, imports, registry) do
    case imported_metadata_signatures(form, registry) do
      {:ok, signatures} -> {nil, MapSet.union(imports, signatures)}
      :error -> {form, imports}
    end
  end

  defp expand_non_definition({name, _, args} = form, imports, _registry)
       when is_atom(name) and is_list(args) do
    if MapSet.member?(imports, {name, length(args)}), do: {nil, imports}, else: {form, imports}
  end

  defp expand_non_definition(form, imports, _registry), do: {form, imports}

  defp imported_metadata_signatures({:import, _, [module_ast]}, registry),
    do: selected_metadata_signatures(module_ast, [], registry)

  defp imported_metadata_signatures({:import, _, [module_ast, options]}, registry)
       when is_list(options),
       do: selected_metadata_signatures(module_ast, options, registry)

  defp imported_metadata_signatures(_form, _registry), do: :error

  defp selected_metadata_signatures(module_ast, options, registry) do
    with {:ok, module} when is_atom(module) <- Literal.eval(module_ast),
         available <- Map.get(registry, module, MapSet.new()),
         true <- MapSet.size(available) > 0 do
      select_signatures(available, options)
    else
      _ -> :error
    end
  end

  defp select_signatures(available, []), do: {:ok, available}

  defp select_signatures(available, only: signatures) do
    with {:ok, requested} <- signature_set(signatures),
         true <- MapSet.subset?(requested, available) do
      {:ok, requested}
    else
      _ -> :error
    end
  end

  defp select_signatures(available, except: signatures) do
    with {:ok, excluded} <- signature_set(signatures),
         true <- MapSet.subset?(excluded, available) do
      {:ok, MapSet.difference(available, excluded)}
    else
      _ -> :error
    end
  end

  defp select_signatures(_available, _options), do: :error

  defp signature_set(signatures) when is_list(signatures) do
    if Enum.all?(signatures, &valid_signature?/1),
      do: {:ok, MapSet.new(signatures)},
      else: :error
  end

  defp signature_set(_signatures), do: :error

  defp valid_signature?({name, arity}),
    do: is_atom(name) and is_integer(arity) and arity >= 0

  defp metadata_macro_signature({:defmacro, _, [head, [do: body]]}) do
    with {:ok, signature} <- definition_head_signature(head),
         true <- metadata_only_body?(body) do
      {:ok, signature}
    else
      _ -> :error
    end
  end

  defp metadata_macro_signature(_form), do: :error

  defp macro_definition_signature({:defmacro, _, [head, [do: _body]]}),
    do: definition_head_signature(head)

  defp macro_definition_signature(_form), do: :error

  defp definition_head_signature({name, _, args}) when is_atom(name) and is_list(args),
    do: {:ok, {name, length(args)}}

  defp definition_head_signature(_head), do: :error

  defp metadata_only_body?({:quote, _, [[do: quoted]]}), do: metadata_quote?(quoted)

  defp metadata_only_body?({:if, _, [condition, branches]}) when is_list(branches) do
    pure_metadata_condition?(condition) and
      metadata_only_body?(Keyword.get(branches, :do)) and
      metadata_only_body?(Keyword.get(branches, :else))
  end

  defp metadata_only_body?(nil), do: true
  defp metadata_only_body?(_body), do: false

  defp pure_metadata_condition?(
         {{:., _, [{:__aliases__, _, [:Version]}, :match?]}, _,
          [
            {{:., _, [{:__aliases__, _, [:System]}, :version]}, _, []},
            requirement
          ]}
       ),
       do: is_binary(requirement)

  defp pure_metadata_condition?(_condition), do: false

  defp metadata_quote?({:__block__, _, forms}), do: Enum.all?(forms, &metadata_quote?/1)

  defp metadata_quote?({:@, _, [{name, _, [_value]}]}) when name in @metadata_attributes,
    do: true

  defp metadata_quote?(_form), do: false

  defp module_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: nil
  end

  defp module_name(module) when is_atom(module), do: module
  defp module_name(_ast), do: nil

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block(forms) do
    case Enum.reject(forms, &is_nil/1) do
      [form] -> form
      forms -> {:__block__, [], forms}
    end
  end
end
