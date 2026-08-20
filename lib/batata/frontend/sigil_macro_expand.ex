defmodule Batata.Frontend.SigilMacroExpand do
  @moduledoc """
  Discovers and expands bounded JSON-decoding sigil providers.

  Providers are inspected structurally and never loaded. Supported sigils
  must delegate to a literal `decode!/2` target through a finite modifier
  mapping. Expansion preserves the decoded value semantics by emitting that
  call explicitly; invalid or dynamic modifiers remain marked unsupported.
  """

  alias Batata.Frontend.Literal

  @type signature :: {:sigil_j | :sigil_J, 2}
  @type registry :: %{optional(module()) => %{optional(signature()) => module()}}
  @modifier_options %{
    ?a => {:keys, :atoms},
    ?A => {:keys, :atoms!},
    ?r => {:strings, :reference},
    ?c => {:strings, :copy}
  }

  @doc "Discovers JSON decoder sigils without executing their macro bodies."
  @spec discover([String.t()]) :: registry()
  def discover(sources) when is_list(sources) do
    Enum.reduce(sources, %{}, fn source, registry ->
      source
      |> Code.string_to_quoted!()
      |> discover_ast(registry)
    end)
  end

  @doc "Consumes supported declarations/imports and expands their calls."
  @spec expand(Macro.t(), registry()) :: Macro.t()
  def expand({:defmodule, metadata, [module_ast, [do: body]]}, registry) do
    module = literal_module(module_ast)
    declared = Map.get(registry, module, %{})

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
    forms = body_forms(body)

    signatures =
      [:sigil_j, :sigil_J]
      |> Enum.reduce(%{}, fn name, signatures ->
        case supported_sigil(forms, name) do
          {:ok, decoder} -> Map.put(signatures, {name, 2}, decoder)
          :error -> signatures
        end
      end)

    if module != nil and map_size(signatures) > 0,
      do: Map.put(registry, module, signatures),
      else: registry
  end

  defp discover_ast(_ast, registry), do: registry

  defp supported_sigil(forms, name) do
    declarations = Enum.filter(forms, &(macro_signature(&1) == {:ok, {name, 2}}))

    declaration_head? = Enum.any?(declarations, &match?({:defmacro, _, [_head]}, &1))
    bodies = Enum.flat_map(declarations, &macro_body/1)

    decoders = bodies |> Enum.flat_map(&decoder_targets/1) |> Enum.uniq()

    if declaration_head? and bodies != [] and
         Enum.all?(bodies, &decode_wrapper?/1) and
         Enum.any?(bodies, &contains_call?(&1, Macro, :escape, 1)) and
         match?([_decoder], decoders) do
      {:ok, hd(decoders)}
    else
      :error
    end
  end

  defp macro_body({:defmacro, _, [_head, [do: body]]}), do: [body]
  defp macro_body(_form), do: []

  defp decode_wrapper?(body) do
    contains_remote_named_call?(body, :decode!, 2) and
      contains_local_call?(body, :mods_to_opts, 1)
  end

  defp contains_call?(ast, module, name, arity) do
    contains?(ast, fn
      {{:., _, [module_ast, ^name]}, _, arguments} when length(arguments) == arity ->
        literal_module(module_ast) == module

      _ ->
        false
    end)
  end

  defp contains_remote_named_call?(ast, name, arity) do
    contains?(ast, fn
      {{:., _, [_module_ast, ^name]}, _, arguments} -> length(arguments) == arity
      _ -> false
    end)
  end

  defp decoder_targets(ast) do
    {_ast, targets} =
      Macro.prewalk(ast, MapSet.new(), fn
        {{:., _, [module_ast, :decode!]}, _, arguments} = call, targets
        when length(arguments) == 2 ->
          case literal_module(module_ast) do
            module when is_atom(module) and not is_nil(module) ->
              {call, MapSet.put(targets, module)}

            _ ->
              {call, targets}
          end

        node, targets ->
          {node, targets}
      end)

    MapSet.to_list(targets)
  end

  defp contains_local_call?(ast, name, arity) do
    contains?(ast, fn
      {^name, _, arguments} when is_list(arguments) -> length(arguments) == arity
      _ -> false
    end)
  end

  defp contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? -> {node, found? or predicate.(node)} end)

    found?
  end

  defp expand_form(form, imports, declared, registry) do
    case macro_signature(form) do
      {:ok, signature} ->
        if Map.has_key?(declared, signature), do: {nil, imports}, else: {form, imports}

      :error ->
        expand_non_definition(form, imports, registry)
    end
  end

  defp expand_non_definition({:import, _, _} = form, imports, registry) do
    case selected_imports(form, registry) do
      {:ok, module, signatures} ->
        imports =
          Enum.reduce(
            signatures,
            imports,
            &Map.put(&2, &1, Map.fetch!(Map.fetch!(registry, module), &1))
          )

        {nil, imports}

      :error ->
        {form, imports}
    end
  end

  defp expand_non_definition({kind, metadata, [head, [do: body]]}, imports, _registry)
       when kind in [:def, :defp] do
    {{kind, metadata, [head, [do: rewrite_calls(body, imports)]]}, imports}
  end

  defp expand_non_definition(form, imports, _registry), do: {form, imports}

  defp rewrite_calls(ast, imports) do
    Macro.postwalk(ast, fn
      {name, metadata, [term, modifiers]} = call when name in [:sigil_j, :sigil_J] ->
        case Map.get(imports, {name, 2}) do
          module when is_atom(module) and not is_nil(module) ->
            expand_sigil(call, module, term, modifiers, metadata)

          _ ->
            call
        end

      node ->
        node
    end)
  end

  defp expand_sigil(_call, decoder, term, modifiers, metadata) do
    case modifier_options(modifiers) do
      {:ok, options} ->
        {{:., metadata,
          [
            {:__aliases__, metadata, Module.split(decoder) |> Enum.map(&String.to_atom/1)},
            :decode!
          ]}, metadata, [term, Macro.escape(options)]}

      :error ->
        {:__batata_unsupported_sigil__, metadata, [term, modifiers]}
    end
  end

  defp modifier_options(modifiers) when is_list(modifiers) do
    modifiers
    |> Enum.reduce_while({:ok, []}, fn modifier, {:ok, options} ->
      case Map.fetch(@modifier_options, modifier) do
        {:ok, option} -> {:cont, {:ok, options ++ [option]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp modifier_options(_modifiers), do: :error

  defp selected_imports({:import, _, [module_ast]}, registry) do
    with module when is_atom(module) and not is_nil(module) <- literal_module(module_ast),
         available when is_map(available) <- Map.get(registry, module),
         true <- map_size(available) > 0 do
      {:ok, module, Map.keys(available)}
    else
      _ -> :error
    end
  end

  defp selected_imports({:import, _, [module_ast, options]}, registry) when is_list(options) do
    with module when is_atom(module) and not is_nil(module) <- literal_module(module_ast),
         available when is_map(available) <- Map.get(registry, module),
         requested when is_list(requested) <- Keyword.get(options, :only),
         signatures <- MapSet.new(requested),
         true <-
           MapSet.size(signatures) > 0 and
             MapSet.subset?(signatures, MapSet.new(Map.keys(available))) do
      {:ok, module, signatures}
    else
      _ -> :error
    end
  end

  defp selected_imports(_form, _registry), do: :error

  defp macro_signature({:defmacro, _, [head]}), do: definition_signature(head)
  defp macro_signature({:defmacro, _, [head, [do: _body]]}), do: definition_signature(head)
  defp macro_signature(_form), do: :error

  defp definition_signature({:when, _, [head, _guard]}), do: definition_signature(head)

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
