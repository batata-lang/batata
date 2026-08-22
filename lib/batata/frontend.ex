defmodule Batata.Frontend do
  @moduledoc """
  Normalized boundary for already-expanded Elixir modules.

  This module deliberately does not implement macro expansion or compile-time
  semantics: it records a normalized module snapshot so later phases can
  consume function clauses without owning them (the frontend boundary).
  """

  defmodule Module do
    @moduledoc "A normalized module snapshot at the expanded-module boundary."
    @enforce_keys [:name, :definitions]
    @type t() :: %__MODULE__{}
    defstruct [
      :name,
      :struct_schema,
      definitions: [],
      unsupported: [],
      struct_schemas: %{},
      protocol_options: %{}
    ]
  end

  defmodule StructSchema do
    @moduledoc "A validated current-module struct declaration with literal defaults."
    @enforce_keys [:module, :kind, :fields]
    @type t() :: %__MODULE__{}
    defstruct [:module, :kind, fields: []]
  end

  defmodule Definition do
    @moduledoc "One normalized function definition with one or more clauses."
    @enforce_keys [:kind, :name, :arity, :clauses]
    @type t() :: %__MODULE__{}
    defstruct [:kind, :name, :arity, clauses: []]
  end

  defmodule Clause do
    @moduledoc "One function clause with patterns and a body AST."
    @enforce_keys [:patterns, :body_ast]
    @type t() :: %__MODULE__{}
    defstruct [:patterns, :guard_ast, :body_ast]
  end

  defmodule UnsupportedForm do
    @moduledoc "A module-body form outside the frontend boundary."
    @enforce_keys [:form, :reason]
    @type t() :: %__MODULE__{}
    defstruct [:form, :reason]
  end

  alias Batata.Frontend.{
    AliasExpand,
    BytecaseExpand,
    DefaultArgExpand,
    MetadataMacroExpand,
    MetaprogrammingExpand,
    ModuleEnvironment,
    RecordExpand,
    RuntimeMacroExpand,
    SigilMacroExpand,
    StaticMapMacroExpand,
    UnicodeEscapeMacroExpand
  }

  @doc """
  Parses source text and normalizes the resulting module AST.

  This parses only. It does not call `Macro.expand/2` or the Elixir compiler.
  """
  @spec from_source(String.t()) :: Module.t() | [Module.t()]
  def from_source(source) when is_binary(source) do
    from_source(source, [])
  end

  @doc false
  @spec from_source(String.t(), keyword()) :: Module.t() | [Module.t()]
  def from_source(source, opts) when is_binary(source) and is_list(opts) do
    {:ok, ast} = Code.string_to_quoted(source)
    from_ast(ast, opts)
  end

  @doc """
  Normalizes multiple sources and shares their struct schemas across the compilation unit.
  """
  @spec from_sources([String.t()]) :: [Module.t()]
  def from_sources(sources) when is_list(sources) do
    metadata_macros = MetadataMacroExpand.discover(sources)
    table_generators = MetaprogrammingExpand.discover_table_generators(sources)
    bytecase_macros = BytecaseExpand.discover(sources)
    static_map_macros = StaticMapMacroExpand.discover(sources)
    sigil_macros = SigilMacroExpand.discover(sources)

    modules =
      Enum.flat_map(sources, fn source ->
        case from_source(source,
               metadata_macros: metadata_macros,
               table_generators: table_generators,
               bytecase_macros: bytecase_macros,
               static_map_macros: static_map_macros,
               sigil_macros: sigil_macros
             ) do
          %Module{} = mod -> [mod]
          mods when is_list(mods) -> mods
        end
      end)

    schemas =
      modules
      |> Enum.reject(&is_nil(&1.struct_schema))
      |> Map.new(&{&1.name, &1.struct_schema})

    Enum.map(modules, fn mod ->
      %{mod | struct_schemas: Map.merge(schemas, mod.struct_schemas || %{})}
    end)
  end

  @doc """
  Normalizes an already-parsed `defmodule` or module-block AST.
  """
  @spec from_ast(Macro.t()) :: Module.t() | [Module.t()]
  def from_ast(ast), do: from_ast(ast, [])

  @doc false
  @spec from_ast(Macro.t(), keyword()) :: Module.t() | [Module.t()]
  def from_ast({:__block__, _, _forms} = block, opts) do
    expanded = MetaprogrammingExpand.expand(block, table_generators(opts))
    {:__block__, _, expanded_forms} = expanded

    if Enum.all?(expanded_forms, &module_form?/1) do
      modules = Enum.flat_map(expanded_forms, &List.wrap(from_ast(&1, opts)))

      schemas =
        modules
        |> Enum.reject(&is_nil(&1.struct_schema))
        |> Map.new(&{&1.name, &1.struct_schema})

      Enum.map(modules, fn mod ->
        %{mod | struct_schemas: Map.merge(schemas, mod.struct_schemas || %{})}
      end)
    else
      block
      |> MetaprogrammingExpand.expand(table_generators(opts))
      |> AliasExpand.expand()
      |> UnicodeEscapeMacroExpand.expand()
      |> StaticMapMacroExpand.expand(static_map_macros(opts))
      |> SigilMacroExpand.expand(sigil_macros(opts))
      |> BytecaseExpand.expand(bytecase_macros(opts))
      |> RecordExpand.expand()
      |> MetadataMacroExpand.expand(metadata_macros(opts))
      |> ModuleEnvironment.expand()
      |> MetaprogrammingExpand.expand(table_generators(opts))
      |> RuntimeMacroExpand.expand()
      |> DefaultArgExpand.expand()
      |> from_expanded_ast()
    end
  end

  def from_ast(ast, opts) do
    ast
    |> MetaprogrammingExpand.expand(table_generators(opts))
    |> AliasExpand.expand()
    |> UnicodeEscapeMacroExpand.expand()
    |> StaticMapMacroExpand.expand(static_map_macros(opts))
    |> SigilMacroExpand.expand(sigil_macros(opts))
    |> BytecaseExpand.expand(bytecase_macros(opts))
    |> RecordExpand.expand()
    |> MetadataMacroExpand.expand(metadata_macros(opts))
    |> ModuleEnvironment.expand()
    |> MetaprogrammingExpand.expand(table_generators(opts))
    |> RuntimeMacroExpand.expand()
    |> DefaultArgExpand.expand()
    |> from_expanded_ast()
  end

  defp metadata_macros(opts), do: Keyword.get(opts, :metadata_macros, %{})
  defp table_generators(opts), do: Keyword.get(opts, :table_generators, MapSet.new())
  defp bytecase_macros(opts), do: Keyword.get(opts, :bytecase_macros, %{})
  defp static_map_macros(opts), do: Keyword.get(opts, :static_map_macros, %{})
  defp sigil_macros(opts), do: Keyword.get(opts, :sigil_macros, %{})

  defp module_form?({kind, _, _}) when kind in [:defmodule, :defimpl, :defprotocol], do: true
  defp module_form?(_form), do: false

  @doc false
  @spec from_expanded_ast(Macro.t()) :: Module.t()
  def from_expanded_ast(
        {:defimpl, meta, [{:__aliases__, _, _protocol_parts} = protocol, [for: targets], body]}
      )
      when is_list(targets) do
    Enum.map(targets, fn target ->
      from_expanded_ast({:defimpl, meta, [protocol, [for: target], body]})
    end)
  end

  def from_expanded_ast(
        {:defimpl, _, [{:__aliases__, _, protocol_parts}, [for: target_ast], [do: body]]}
      ) do
    protocol = Elixir.Module.concat(protocol_parts)
    target = normalize_defimpl_target!(target_ast)

    impl_module = Elixir.Module.concat(protocol, target)

    {definitions, unsupported, struct_schema} =
      body
      |> AliasExpand.expand_body(impl_module)
      |> expand_defimpl_attributes(protocol, target)
      |> body_forms()
      |> normalize_body(impl_module)

    %Module{
      name: impl_module,
      definitions: definitions,
      unsupported: unsupported,
      struct_schema: struct_schema,
      struct_schemas: %{}
    }
  end

  def from_expanded_ast({:defprotocol, _, [{:__aliases__, _, name_parts}, [do: body]]}) do
    module = Elixir.Module.concat(name_parts)
    {protocol_options, forms} = body |> body_forms() |> extract_protocol_options()

    {definitions, unsupported, _schema} =
      forms
      |> Enum.reject(&metadata_attribute?/1)
      |> normalize_protocol_body(module)

    %Module{
      name: module,
      definitions: definitions,
      unsupported: unsupported,
      struct_schemas: %{},
      protocol_options: protocol_options
    }
  end

  def from_expanded_ast({:defmodule, _, [{:__aliases__, _, name_parts}, [do: body]]}) do
    module = Elixir.Module.concat(name_parts)
    {definitions, unsupported, struct_schema} = body |> body_forms() |> normalize_body(module)

    struct_schemas =
      if struct_schema != nil do
        %{module => struct_schema}
      else
        %{}
      end

    %Module{
      name: module,
      definitions: definitions,
      unsupported: unsupported,
      struct_schema: struct_schema,
      struct_schemas: struct_schemas
    }
  end

  defp extract_protocol_options(forms) do
    Enum.reduce(forms, {%{}, []}, fn
      {:@, _, [{:fallback_to_any, _, [value]}]}, {options, kept} when is_boolean(value) ->
        {Map.put(options, :fallback_to_any, value), kept}

      form, {options, kept} ->
        {options, kept ++ [form]}
    end)
  end

  defp normalize_defimpl_target!({:__aliases__, _, target_parts}) do
    Elixir.Module.concat(target_parts)
  end

  defp normalize_defimpl_target!(target) when is_atom(target), do: target

  defp normalize_defimpl_target!(target) do
    raise ArgumentError, "unsupported defimpl target: #{Macro.to_string(target)}"
  end

  defp expand_defimpl_attributes({kind, _, _} = ast, _protocol, _target)
       when kind in [:defmodule, :defprotocol, :defimpl],
       do: ast

  defp expand_defimpl_attributes({:@, _, [{:protocol, _, nil}]}, protocol, _target),
    do: Macro.escape(protocol)

  defp expand_defimpl_attributes({:@, _, [{:for, _, nil}]}, _protocol, target),
    do: Macro.escape(target)

  defp expand_defimpl_attributes(tuple, protocol, target) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&expand_defimpl_attributes(&1, protocol, target))
    |> List.to_tuple()
  end

  defp expand_defimpl_attributes(values, protocol, target) when is_list(values),
    do: Enum.map(values, &expand_defimpl_attributes(&1, protocol, target))

  defp expand_defimpl_attributes(other, _protocol, _target), do: other

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: List.wrap(form)

  defp normalize_body(forms, module) do
    forms
    |> Enum.reduce({[], [], nil}, &normalize_body_form(&1, &2, module))
    |> then(fn {definitions, unsupported, schema} ->
      schema = if schema == :invalid, do: nil, else: schema
      {Enum.reverse(definitions), Enum.reverse(unsupported), schema}
    end)
  end

  defp normalize_body_form(form, accumulator, module) do
    if metadata_attribute?(form),
      do: accumulator,
      else: normalize_body_form(form, accumulator, module, normalize_form(form, module))
  end

  defp normalize_body_form(_form, {definitions, unsupported, schema}, _module, {:ok, definition}),
    do: {[definition | definitions], unsupported, schema}

  defp normalize_body_form(_form, {definitions, unsupported, nil}, _module, {:schema, schema}),
    do: {definitions, unsupported, schema}

  defp normalize_body_form(
         form,
         {definitions, unsupported, _existing_schema},
         _module,
         {:schema, _new_schema}
       ),
       do:
         {definitions,
          [%UnsupportedForm{form: form, reason: :duplicate_struct_schema} | unsupported],
          :invalid}

  defp normalize_body_form(
         form,
         {definitions, unsupported, _schema},
         _module,
         {:unsupported, :invalid_struct_schema = reason}
       ),
       do: {definitions, [%UnsupportedForm{form: form, reason: reason} | unsupported], :invalid}

  defp normalize_body_form(
         form,
         {definitions, unsupported, schema},
         _module,
         {:unsupported, reason}
       ),
       do: {definitions, [%UnsupportedForm{form: form, reason: reason} | unsupported], schema}

  defp normalize_protocol_body(forms, module) do
    forms
    |> Enum.reduce({[], [], nil}, fn
      {:def, _, [{name, _, args}]}, {definitions, unsupported, schema}
      when is_atom(name) and is_list(args) ->
        definition = %Definition{
          kind: :def,
          name: name,
          arity: length(args),
          clauses: [
            %Clause{
              patterns: args,
              body_ast: {:__protocol_dispatch__, [], [module, name, length(args)]}
            }
          ]
        }

        {definitions ++ [definition], unsupported, schema}

      form, {definitions, unsupported, schema} ->
        case normalize_form(form, module) do
          {:ok, definition} ->
            {definitions ++ [definition], unsupported, schema}

          {:unsupported, reason} ->
            {definitions, unsupported ++ [%UnsupportedForm{form: form, reason: reason}], schema}
        end
    end)
  end

  defp metadata_attribute?({:@, _, [{name, _, _}]})
       when name in [
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
            ],
       do: true

  defp metadata_attribute?(_form), do: false

  defp normalize_form({kind, _, [{name, _, args}, [do: body_ast]]}, _module)
       when kind in [:def, :defp] and is_atom(name) and name != :when and is_list(args) do
    {:ok,
     %Definition{
       kind: kind,
       name: name,
       arity: length(args),
       clauses: [%Clause{patterns: args, body_ast: body_ast}]
     }}
  end

  defp normalize_form(
         {kind, _, [{:when, _, [{name, _, args}, guard_ast]}, [do: body_ast]]},
         _module
       )
       when kind in [:def, :defp] and is_atom(name) and is_list(args) do
    {:ok,
     %Definition{
       kind: kind,
       name: name,
       arity: length(args),
       clauses: [%Clause{patterns: args, guard_ast: guard_ast, body_ast: body_ast}]
     }}
  end

  defp normalize_form({kind, _, [fields]}, module)
       when kind in [:defstruct, :defexception] do
    case normalize_struct_fields(fields) do
      {:ok, normalized_fields} ->
        schema_kind = if kind == :defexception, do: :exception, else: :struct
        {:schema, %StructSchema{module: module, kind: schema_kind, fields: normalized_fields}}

      :error ->
        {:unsupported, :invalid_struct_schema}
    end
  end

  defp normalize_form({:@, _, _}, _module), do: {:unsupported, :module_attribute}
  defp normalize_form({:require, _, _}, _module), do: {:unsupported, :require}
  defp normalize_form({:import, _, _}, _module), do: {:unsupported, :import}
  defp normalize_form({:use, _, _}, _module), do: {:unsupported, :use}
  defp normalize_form({:defmodule, _, _}, _module), do: {:unsupported, :nested_defmodule}
  defp normalize_form(_other, _module), do: {:unsupported, :unknown_form}

  defp normalize_struct_fields(fields) when is_list(fields) do
    fields
    |> Enum.reduce_while({[], MapSet.new()}, fn
      field, {fields, seen} when is_atom(field) ->
        append_struct_field(field, nil, fields, seen)

      {field, default}, {fields, seen} when is_atom(field) ->
        if Macro.quoted_literal?(default) do
          append_struct_field(field, default, fields, seen)
        else
          {:halt, :error}
        end

      _field, _acc ->
        {:halt, :error}
    end)
    |> case do
      :error -> :error
      {normalized, _seen} -> {:ok, Enum.reverse(normalized)}
    end
  end

  defp normalize_struct_fields(_fields), do: :error

  defp append_struct_field(field, default, fields, seen) do
    if field in [:__struct__, :__exception__] or MapSet.member?(seen, field) do
      {:halt, :error}
    else
      {:cont, {[{field, default} | fields], MapSet.put(seen, field)}}
    end
  end
end
