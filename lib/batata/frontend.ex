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
    defstruct [:name, :struct_schema, definitions: [], unsupported: []]
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

  alias Batata.Frontend.{AliasExpand, DefaultArgExpand, MetaprogrammingExpand}

  @doc """
  Parses source text and normalizes the resulting module AST.

  This parses only. It does not call `Macro.expand/2` or the Elixir compiler.
  """
  @spec from_source(String.t()) :: Module.t()
  def from_source(source) when is_binary(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    from_ast(ast)
  end

  @doc """
  Normalizes an already-parsed `defmodule` AST.
  """
  @spec from_ast(Macro.t()) :: Module.t()
  def from_ast(ast) do
    ast
    |> MetaprogrammingExpand.expand()
    |> AliasExpand.expand()
    |> DefaultArgExpand.expand()
    |> from_expanded_ast()
  end

  @doc false
  @spec from_expanded_ast(Macro.t()) :: Module.t()
  def from_expanded_ast({:defmodule, _, [{:__aliases__, _, name_parts}, [do: body]]}) do
    module = Elixir.Module.concat(name_parts)
    {definitions, unsupported, struct_schema} = body |> body_forms() |> normalize_body(module)

    %Module{
      name: module,
      definitions: definitions,
      unsupported: unsupported,
      struct_schema: struct_schema
    }
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: List.wrap(form)

  defp normalize_body(forms, module) do
    forms
    |> Enum.reduce({[], [], nil}, fn form, {definitions, unsupported, schema} ->
      case normalize_form(form, module) do
        {:ok, definition} ->
          {[definition | definitions], unsupported, schema}

        {:schema, new_schema} when schema == nil ->
          {definitions, unsupported, new_schema}

        {:schema, _new_schema} ->
          unsupported = [
            %UnsupportedForm{form: form, reason: :duplicate_struct_schema} | unsupported
          ]

          {definitions, unsupported, :invalid}

        {:unsupported, :invalid_struct_schema = reason} ->
          {definitions, [%UnsupportedForm{form: form, reason: reason} | unsupported], :invalid}

        {:unsupported, reason} ->
          {definitions, [%UnsupportedForm{form: form, reason: reason} | unsupported], schema}
      end
    end)
    |> then(fn {definitions, unsupported, schema} ->
      schema = if schema == :invalid, do: nil, else: schema
      {Enum.reverse(definitions), Enum.reverse(unsupported), schema}
    end)
  end

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
