defmodule Batata.Frontend.StaticMapMacroExpand do
  @moduledoc """
  Expands bounded, compile-time keyed map encoder macros without loading providers.

  The accepted providers build quoted fragment structs through a
  `build_kv_iodata/2` helper. Calls are accepted only when their keys are
  literal, JSON-safe atoms or binaries; all other shapes remain visible to the
  frontend as unsupported imports or requires.
  """

  alias Batata.Frontend.{AliasExpand, Literal}

  @type macro_kind :: :literal_map | :map_take | :deriving
  @type macro_spec :: %{
          required(:kind) => macro_kind(),
          optional(:fragment_module) => module(),
          optional(:encode_module) => module(),
          optional(:protocol) => module()
        }
  @type signature :: {atom(), non_neg_integer()}
  @type registry :: %{optional(module()) => %{optional(signature()) => macro_spec()}}

  @doc "Discovers supported map encoder macros in parsed source strings."
  @spec discover([String.t()]) :: registry()
  def discover(sources) when is_list(sources) do
    Enum.reduce(sources, %{}, fn source, registry ->
      source
      |> Code.string_to_quoted!()
      |> AliasExpand.expand()
      |> discover_ast(registry)
    end)
  end

  @doc "Expands bounded `@derive` declarations into ordinary protocol implementations."
  @spec expand_derivations(Macro.t(), registry()) :: Macro.t()
  def expand_derivations({:__block__, metadata, forms}, registry) do
    expanded =
      Enum.flat_map(forms, fn form ->
        case expand_derivations(form, registry) do
          {:__block__, _, nested} -> nested
          expanded_form -> [expanded_form]
        end
      end)

    {:__block__, metadata, expanded}
  end

  def expand_derivations({:defmodule, metadata, [module_ast, [do: body]]} = ast, registry) do
    module = literal_module(module_ast)
    forms = body_forms(body)

    case derive_implementations(module, forms, registry, metadata) do
      {[], _consumed} ->
        ast

      {implementations, consumed} ->
        kept = Enum.reject(forms, &MapSet.member?(consumed, &1))
        target = {:defmodule, metadata, [module_ast, [do: block(kept)]]}
        {:__block__, metadata, [target | implementations]}
    end
  end

  def expand_derivations(ast, _registry), do: ast

  @doc "Consumes supported declarations and expands imported or required calls."
  @spec expand(Macro.t(), registry()) :: Macro.t()
  def expand({:defmodule, metadata, [module_ast, [do: body]]}, registry) do
    module = literal_module(module_ast)
    declared = Map.get(registry, module, %{})

    {forms, state} =
      body
      |> body_forms()
      |> Enum.map_reduce(%{imports: %{}, requires: MapSet.new()}, fn form, state ->
        expand_form(form, state, declared, registry)
      end)

    unresolved? = Map.get(state, :unresolved?, false)

    forms =
      if unresolved? do
        forms
      else
        Enum.reject(forms, &is_nil/1)
      end

    {:defmodule, metadata, [module_ast, [do: block(forms)]]}
  end

  def expand({:defimpl, metadata, arguments}, registry) do
    {prefix, [[do: body]]} = Enum.split(arguments, length(arguments) - 1)
    module = impl_module(prefix)
    declared = Map.get(registry, module, %{})

    forms =
      body
      |> body_forms()
      |> Enum.map(&consume_declared_macro(&1, declared))
      |> Enum.reject(&is_nil/1)

    {:defimpl, metadata, prefix ++ [[do: block(forms)]]}
  end

  def expand(ast, _registry), do: ast

  defp consume_declared_macro(form, declared) do
    case macro_definition_signature(form) do
      {:ok, signature} -> keep_unless_declared(form, signature, declared)
      :error -> form
    end
  end

  defp keep_unless_declared(form, signature, declared) do
    if Map.has_key?(declared, signature), do: nil, else: form
  end

  defp discover_ast({:__block__, _, forms}, registry),
    do: Enum.reduce(forms, registry, &discover_ast/2)

  defp discover_ast({:defmodule, _, [module_ast, [do: body]]}, registry) do
    module = literal_module(module_ast)

    macros =
      body
      |> body_forms()
      |> Enum.reduce(%{}, fn form, acc ->
        case macro_kind(form, module) do
          {:ok, signature, spec} -> Map.put(acc, signature, spec)
          :error -> acc
        end
      end)

    if module != nil and map_size(macros) > 0,
      do: Map.put(registry, module, macros),
      else: registry
  end

  defp discover_ast({:defimpl, _, arguments}, registry) do
    {prefix, [[do: body]]} = Enum.split(arguments, length(arguments) - 1)
    module = impl_module(prefix)

    macros =
      body
      |> body_forms()
      |> Enum.reduce(%{}, fn form, acc ->
        case macro_kind(form, module) do
          {:ok, signature, spec} -> Map.put(acc, signature, spec)
          :error -> acc
        end
      end)

    if module != nil and map_size(macros) > 0,
      do: Map.put(registry, module, macros),
      else: registry
  end

  defp discover_ast(_ast, registry), do: registry

  defp macro_kind({:defmacro, _, [head, [do: body]]}, provider) do
    with {:ok, {name, arity} = signature} <- definition_signature(head),
         true <- calls_build_kv_iodata?(body),
         {:ok, spec} <- map_macro_kind(name, arity, body, provider) do
      {:ok, signature, spec}
    else
      _ -> :error
    end
  end

  defp macro_kind(_form, _provider), do: :error

  defp map_macro_kind(_name, 1, body, _provider) do
    with {:ok, fragment_module} <- fragment_module(body),
         encode_module when is_atom(encode_module) <- sibling_module(fragment_module, :Encode) do
      {:ok, %{kind: :literal_map, fragment_module: fragment_module, encode_module: encode_module}}
    else
      _ -> :error
    end
  end

  defp map_macro_kind(_name, 2, body, _provider) do
    with true <- contains?(body, &match?({:case, _, _}, &1)),
         {:ok, fragment_module} <- fragment_module(body),
         encode_module when is_atom(encode_module) <- sibling_module(fragment_module, :Encode) do
      {:ok, %{kind: :map_take, fragment_module: fragment_module, encode_module: encode_module}}
    else
      _ -> :error
    end
  end

  defp map_macro_kind(:__deriving__, 3, body, provider) do
    with true <- contains?(body, &match?({:defimpl, _, _}, &1)),
         protocol when is_atom(protocol) <- parent_protocol(provider),
         encode_module when is_atom(encode_module) <- sibling_module(protocol, :Encode) do
      {:ok, %{kind: :deriving, protocol: protocol, encode_module: encode_module}}
    else
      _ -> :error
    end
  end

  defp map_macro_kind(_name, _arity, _body, _provider), do: :error

  defp derive_implementations(module, forms, registry, metadata)
       when is_atom(module) and not is_nil(module) do
    case struct_fields(forms) do
      {:ok, fields, _struct_form} ->
        Enum.reduce(forms, {[], MapSet.new()}, fn form, acc ->
          append_derived_implementation(form, module, fields, registry, metadata, acc)
        end)

      _other ->
        {[], MapSet.new()}
    end
  end

  defp derive_implementations(_module, _forms, _registry, _metadata),
    do: {[], MapSet.new()}

  defp append_derived_implementation(
         form,
         module,
         fields,
         registry,
         metadata,
         {implementations, consumed} = unchanged
       ) do
    with {:ok, spec, options} <- derive_spec(form, registry),
         {:ok, selected} <- derived_fields(fields, options) do
      implementation = derive_impl_ast(module, selected, spec, metadata)
      {implementations ++ [implementation], MapSet.put(consumed, form)}
    else
      _other -> unchanged
    end
  end

  defp derive_spec({:@, _, [{:derive, _, [value]}]}, registry) do
    with {:ok, protocol, options} <- derive_value(value),
         provider <- Module.concat(protocol, Any),
         macros when is_map(macros) <- Map.get(registry, provider),
         %{kind: :deriving, protocol: ^protocol} = spec <- Map.get(macros, {:__deriving__, 3}) do
      {:ok, spec, options}
    else
      _ -> :error
    end
  end

  defp derive_spec(_form, _registry), do: :error

  defp derive_value({:{}, _, [protocol_ast, options]}) when is_list(options) do
    case literal_module(protocol_ast) do
      protocol when is_atom(protocol) and not is_nil(protocol) -> {:ok, protocol, options}
      _ -> :error
    end
  end

  defp derive_value({protocol_ast, options}) when is_list(options) do
    case literal_module(protocol_ast) do
      protocol when is_atom(protocol) and not is_nil(protocol) -> {:ok, protocol, options}
      _ -> :error
    end
  end

  defp derive_value(protocol_ast) do
    case literal_module(protocol_ast) do
      protocol when is_atom(protocol) and not is_nil(protocol) -> {:ok, protocol, []}
      _ -> :error
    end
  end

  defp struct_fields(forms) do
    Enum.find_value(forms, :error, fn
      {:defstruct, _, [fields]} = form when is_list(fields) ->
        names =
          Enum.map(fields, fn
            {name, _default} -> name
            name -> name
          end)

        if Enum.all?(names, &is_atom/1), do: {:ok, names, form}, else: false

      _ ->
        false
    end)
  end

  defp derived_fields(fields, options) do
    cond do
      Keyword.keyword?(options) and is_list(options[:only]) and
          Enum.all?(options[:only], &(&1 in fields)) ->
        {:ok, options[:only]}

      Keyword.keyword?(options) and is_list(options[:except]) and
          Enum.all?(options[:except], &(&1 in fields)) ->
        {:ok, fields -- options[:except]}

      options == [] ->
        {:ok, fields}

      true ->
        :error
    end
  end

  defp derive_impl_ast(module, fields, spec, metadata) do
    variables = generated_vars(Enum.map(fields, &{&1, nil}))
    pairs = Enum.zip(fields, variables)
    pattern = {:%{}, metadata, pairs}
    escape = Macro.var(:escape, __MODULE__)
    encode_map = Macro.var(:encode_map, __MODULE__)
    opts = {:{}, metadata, [escape, encode_map]}
    body = iodata_ast(pairs, escape, encode_map, spec.encode_module, metadata)
    head = {:encode, metadata, [pattern, opts]}
    definition = {:def, metadata, [head, [do: body]]}

    {:defimpl, metadata,
     [module_ast(spec.protocol, metadata), [for: module_ast(module, metadata)], [do: definition]]}
  end

  defp parent_protocol(provider) when is_atom(provider) do
    case Module.split(provider) do
      [_single] -> nil
      parts -> parts |> Enum.drop(-1) |> Module.concat()
    end
  end

  defp parent_protocol(_provider), do: nil

  defp calls_build_kv_iodata?(ast) do
    contains?(ast, fn
      {{:., _, [_module, :build_kv_iodata]}, _, [_kv, _args]} -> true
      _ -> false
    end)
  end

  defp fragment_module(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:%, _, [module_ast, {:%{}, _, _}]} = node, modules ->
          {node, put_fragment_module(modules, module_ast)}

        node, modules ->
          {node, modules}
      end)

    case MapSet.to_list(modules) do
      [module] -> {:ok, module}
      _ -> :error
    end
  end

  defp put_fragment_module(modules, module_ast) do
    case literal_module(module_ast) do
      module when is_atom(module) and not is_nil(module) ->
        if module |> Module.split() |> List.last() == "Fragment",
          do: MapSet.put(modules, module),
          else: modules

      _ ->
        modules
    end
  end

  defp sibling_module(module, final_part) do
    case Module.split(module) do
      [] -> nil
      parts -> parts |> List.replace_at(-1, Atom.to_string(final_part)) |> Module.concat()
    end
  end

  defp contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? -> {node, found? or predicate.(node)} end)

    found?
  end

  defp expand_form(form, state, declared, registry) do
    case macro_definition_signature(form) do
      {:ok, signature} ->
        if Map.has_key?(declared, signature), do: {nil, state}, else: {form, state}

      :error ->
        expand_non_definition(form, state, registry)
    end
  end

  defp expand_non_definition({:import, _, _} = form, state, registry) do
    case selected_imports(form, registry) do
      {:ok, module, signatures} ->
        imports =
          Enum.reduce(
            signatures,
            state.imports,
            &Map.put(&2, &1, {module, Map.fetch!(Map.fetch!(registry, module), &1)})
          )

        {nil, %{state | imports: imports}}

      :error ->
        {form, state}
    end
  end

  defp expand_non_definition({:require, _, [module_ast]} = form, state, registry) do
    case literal_module(module_ast) do
      module when is_atom(module) and not is_nil(module) ->
        if Map.has_key?(registry, module) do
          {nil, %{state | requires: MapSet.put(state.requires, module)}}
        else
          {form, state}
        end

      nil ->
        {form, state}
    end
  end

  defp expand_non_definition({kind, metadata, [head, [do: body]]}, state, registry)
       when kind in [:def, :defp] do
    {body, unresolved?} = rewrite_calls(body, state, registry)
    state = if unresolved?, do: Map.put(state, :unresolved?, true), else: state
    {{kind, metadata, [head, [do: body]]}, state}
  end

  defp expand_non_definition(form, state, _registry), do: {form, state}

  defp rewrite_calls(ast, state, registry) do
    Macro.postwalk(ast, false, fn
      {name, _, arguments} = call, unresolved? when is_atom(name) and is_list(arguments) ->
        signature = {name, length(arguments)}

        case Map.get(state.imports, signature) do
          {_module, spec} -> expand_call(call, spec, unresolved?)
          nil -> {call, unresolved?}
        end

      {{:., _, [module_ast, name]}, _, arguments} = call, unresolved?
      when is_atom(name) and is_list(arguments) ->
        module = literal_module(module_ast)
        signature = {name, length(arguments)}

        with true <- MapSet.member?(state.requires, module),
             module_macros when is_map(module_macros) <- Map.get(registry, module),
             spec when is_map(spec) <- Map.get(module_macros, signature) do
          expand_call(call, spec, unresolved?)
        else
          _ -> {call, unresolved?}
        end

      node, unresolved? ->
        {node, unresolved?}
    end)
  end

  defp expand_call(
         {_, metadata, [kv]},
         %{kind: :literal_map} = spec,
         unresolved?
       ) do
    case literal_pairs(kv) do
      {:ok, pairs} -> {literal_map_ast(pairs, spec, metadata), unresolved?}
      :error -> {{:__batata_unsupported_static_map_macro__, metadata, [kv]}, true}
    end
  end

  defp expand_call(
         {_, metadata, [map, keys]},
         %{kind: :map_take} = spec,
         unresolved?
       ) do
    case literal_keys(keys) do
      {:ok, keys} -> {map_take_ast(map, keys, spec, metadata), unresolved?}
      :error -> {{:__batata_unsupported_static_map_macro__, metadata, [map, keys]}, true}
    end
  end

  defp expand_call(call, _kind, _unresolved?), do: {call, true}

  defp literal_pairs(ast) when is_list(ast) do
    ast
    |> Enum.reduce_while({:ok, []}, fn
      {key, value}, {:ok, pairs} ->
        if safe_key?(key), do: {:cont, {:ok, pairs ++ [{key, value}]}}, else: {:halt, :error}

      _, _ ->
        {:halt, :error}
    end)
  end

  defp literal_pairs(_ast), do: :error

  defp literal_keys(ast) do
    case Literal.eval(ast) do
      {:ok, keys} when is_list(keys) ->
        if length(keys) <= 512 and Enum.all?(keys, &safe_key?/1), do: {:ok, keys}, else: :error

      _ ->
        :error
    end
  end

  defp safe_key?(key) when is_atom(key), do: safe_key?(Atom.to_string(key))

  defp safe_key?(key) when is_binary(key) do
    byte_size(key) > 0 and
      Enum.all?(:binary.bin_to_list(key), &(&1 >= 0x1F and &1 <= 0x7F and &1 not in ~c'"\\/'))
  end

  defp safe_key?(_key), do: false

  defp literal_map_ast(pairs, spec, metadata) do
    vars = generated_vars(pairs)
    values = Enum.map(pairs, &elem(&1, 1))
    fragment = fragment_ast(Enum.zip(Enum.map(pairs, &elem(&1, 0)), vars), spec, metadata)

    if pairs == [] do
      fragment
    else
      {:=, metadata, [{:{}, metadata, vars}, {:{}, metadata, values}]}
      |> then(&{:__block__, metadata, [&1, fragment]})
    end
  end

  defp map_take_ast(map, keys, spec, metadata) do
    vars = generated_vars(Enum.map(keys, &{&1, nil}))
    pairs = Enum.zip(keys, vars)
    pattern = {:%{}, metadata, pairs}
    fragment = fragment_ast(pairs, spec, metadata)
    other = Macro.var(:other, __MODULE__)
    message = "expected a map with keys: #{inspect(keys)}"

    {:case, metadata,
     [
       map,
       [
         do: [
           {:->, metadata, [[pattern], fragment]},
           {:->, metadata,
            [[other], {:raise, metadata, [{:__aliases__, metadata, [:ArgumentError]}, message]}]}
         ]
       ]
     ]}
  end

  defp generated_vars(pairs) do
    pairs
    |> Enum.with_index()
    |> Enum.map(fn {_pair, index} ->
      Macro.var(String.to_atom("__batata_map_value_#{index}"), __MODULE__)
    end)
  end

  defp fragment_ast(pairs, spec, metadata) do
    escape = Macro.var(:escape, __MODULE__)
    encode_map = Macro.var(:encode_map, __MODULE__)
    iodata = iodata_ast(pairs, escape, encode_map, spec.encode_module, metadata)
    argument = {:{}, metadata, [escape, encode_map]}
    closure = {:fn, metadata, [{:->, metadata, [[argument], iodata]}]}

    {:%, metadata,
     [
       module_ast(spec.fragment_module, metadata),
       {:%{}, metadata, [encode: closure]}
     ]}
  end

  defp iodata_ast([], _escape, _encode_map, _encode_module, _metadata), do: "{}"

  defp iodata_ast(pairs, escape, encode_map, encode_module, metadata) do
    dynamic =
      pairs
      |> Enum.with_index()
      |> Enum.flat_map(fn {{key, variable}, index} ->
        prefix = if index == 0, do: "{", else: ","
        key = if is_atom(key), do: Atom.to_string(key), else: key
        static = prefix <> "\"" <> key <> "\":"

        call =
          {{:., metadata, [module_ast(encode_module, metadata), :value]}, metadata,
           [variable, escape, encode_map]}

        [static, call]
      end)

    dynamic ++ ["}"]
  end

  defp selected_imports({:import, _, [module_ast, options]}, registry) when is_list(options) do
    with module when is_atom(module) <- literal_module(module_ast),
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

  defp module_ast(module, metadata) do
    parts = module |> Module.split() |> Enum.map(&String.to_atom/1)
    {:__aliases__, metadata, parts}
  end

  defp impl_module([protocol_ast, [for: target_ast]]) do
    with protocol when is_atom(protocol) <- literal_module(protocol_ast),
         target when is_atom(target) <- literal_module(target_ast),
         false <- is_nil(protocol) or is_nil(target) do
      Module.concat(protocol, target)
    else
      _ -> nil
    end
  end

  defp impl_module(_prefix), do: nil

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block([form]), do: form
  defp block(forms), do: {:__block__, [], forms}
end
