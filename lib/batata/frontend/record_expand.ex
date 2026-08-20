defmodule Batata.Frontend.RecordExpand do
  @moduledoc """
  Expands bounded private records into tuple constructors, patterns, accessors,
  and updates.

  Only literal field declarations behind a lexical Record import are accepted.
  Unknown fields, duplicate fields, and unsupported options remain visible.
  """

  alias Batata.Frontend.Literal

  @type schema :: [{atom(), Macro.t()}]

  @doc "Expands supported private record forms in one module."
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, metadata, [name_ast, [do: body]]}) do
    forms = body_forms(body)
    supported_declaration? = Enum.any?(forms, &match?({:ok, _, _}, record_declaration(&1)))

    {forms, _state} =
      Enum.map_reduce(
        forms,
        %{record_imported?: false, schemas: %{}},
        &expand_form(&1, &2, supported_declaration?)
      )

    {:defmodule, metadata, [name_ast, [do: block(forms)]]}
  end

  def expand(ast), do: ast

  defp expand_form({:import, _, _} = form, state, supported_declaration?) do
    if supported_declaration? and record_import?(form) do
      {nil, %{state | record_imported?: true}}
    else
      {form, state}
    end
  end

  defp expand_form(form, %{record_imported?: true} = state, _supported_declaration?) do
    case record_declaration(form) do
      {:ok, name, schema} ->
        {nil, put_in(state, [:schemas, name], schema)}

      :error ->
        {rewrite_module_form(form, state.schemas), state}
    end
  end

  defp expand_form(form, state, _supported_declaration?),
    do: {rewrite_module_form(form, state.schemas), state}

  defp record_import?({:import, _, [module_ast]}) do
    Literal.eval(module_ast) == {:ok, Record}
  end

  defp record_import?(_form), do: false

  defp record_declaration({:defrecordp, _, [name, fields]}) when is_atom(name) do
    case normalize_fields(fields) do
      {:ok, schema} -> {:ok, name, schema}
      :error -> :error
    end
  end

  defp record_declaration(_form), do: :error

  defp normalize_fields(fields) when is_list(fields) do
    fields
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn field, {:ok, schema, seen} ->
      with {:ok, name, default} <- normalize_field(field),
           false <- MapSet.member?(seen, name) do
        {:cont, {:ok, schema ++ [{name, default}], MapSet.put(seen, name)}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, schema, _seen} -> {:ok, schema}
      :error -> :error
    end
  end

  defp normalize_fields(_fields), do: :error

  defp normalize_field(name) when is_atom(name), do: {:ok, name, nil}

  defp normalize_field({name, default}) when is_atom(name) do
    if Macro.quoted_literal?(default), do: {:ok, name, default}, else: :error
  end

  defp normalize_field(_field), do: :error

  defp rewrite_module_form({kind, metadata, [head, [do: body]]}, schemas)
       when kind in [:def, :defp] do
    head = rewrite_definition_head(head, schemas)
    body = rewrite(body, :expression, schemas)
    {kind, metadata, [head, [do: body]]}
  end

  defp rewrite_module_form(form, _schemas), do: form

  defp rewrite_definition_head({:when, metadata, heads_and_guard}, schemas) do
    {heads, [guard]} = Enum.split(heads_and_guard, length(heads_and_guard) - 1)
    heads = Enum.map(heads, &rewrite(&1, :match, schemas))
    {:when, metadata, heads ++ [rewrite(guard, :expression, schemas)]}
  end

  defp rewrite_definition_head(head, schemas), do: rewrite(head, :match, schemas)

  defp rewrite({:=, metadata, [left, right]}, _context, schemas) do
    {:=, metadata, [rewrite(left, :match, schemas), rewrite(right, :expression, schemas)]}
  end

  defp rewrite({:->, metadata, [patterns, body]}, _context, schemas) when is_list(patterns) do
    patterns = Enum.map(patterns, &rewrite(&1, :match, schemas))
    {:->, metadata, [patterns, rewrite(body, :expression, schemas)]}
  end

  defp rewrite({name, metadata, [fields]} = form, context, schemas)
       when is_atom(name) and is_list(fields) do
    case Map.fetch(schemas, name) do
      {:ok, schema} -> record_constructor(name, metadata, fields, schema, context, schemas, form)
      :error -> rewrite_tuple(form, context, schemas)
    end
  end

  defp rewrite({name, metadata, [record, field]} = form, context, schemas)
       when is_atom(name) and is_atom(field) do
    case Map.fetch(schemas, name) do
      {:ok, schema} -> record_accessor(metadata, record, field, schema, schemas, form)
      :error -> rewrite_tuple(form, context, schemas)
    end
  end

  defp rewrite({name, metadata, [record, updates]} = form, context, schemas)
       when is_atom(name) and is_list(updates) do
    case Map.fetch(schemas, name) do
      {:ok, schema} -> record_update(metadata, record, updates, schema, schemas, form)
      :error -> rewrite_tuple(form, context, schemas)
    end
  end

  defp rewrite(tuple, context, schemas) when is_tuple(tuple),
    do: rewrite_tuple(tuple, context, schemas)

  defp rewrite(values, context, schemas) when is_list(values),
    do: Enum.map(values, &rewrite(&1, context, schemas))

  defp rewrite(other, _context, _schemas), do: other

  defp rewrite_tuple(tuple, context, schemas) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&rewrite(&1, context, schemas))
    |> List.to_tuple()
  end

  defp record_constructor(name, metadata, fields, schema, context, schemas, fallback) do
    case keyword_values(fields, schema) do
      {:ok, values} ->
        fields =
          Enum.map(schema, &constructor_field(&1, values, metadata, context, schemas))

        {:{}, metadata, [name | fields]}

      :error ->
        fallback
    end
  end

  defp constructor_field({field, default}, values, metadata, context, schemas) do
    case Map.fetch(values, field) do
      {:ok, value} -> rewrite(value, context, schemas)
      :error when context == :match -> {:_, metadata, nil}
      :error -> default
    end
  end

  defp record_accessor(metadata, record, field, schema, schemas, fallback) do
    case field_index(schema, field) do
      {:ok, index} -> {:elem, metadata, [rewrite(record, :expression, schemas), index]}
      :error -> fallback
    end
  end

  defp record_update(metadata, record, updates, schema, schemas, fallback) do
    case keyword_values(updates, schema) do
      {:ok, values} ->
        Enum.reduce(values, rewrite(record, :expression, schemas), fn {field, value}, record ->
          {:ok, index} = field_index(schema, field)
          {:put_elem, metadata, [record, index, rewrite(value, :expression, schemas)]}
        end)

      :error ->
        fallback
    end
  end

  defp keyword_values(values, schema) do
    known = MapSet.new(schema, &elem(&1, 0))

    values
    |> Enum.reduce_while({:ok, %{}}, fn
      {field, value}, {:ok, acc} when is_atom(field) ->
        if MapSet.member?(known, field) and not Map.has_key?(acc, field) do
          {:cont, {:ok, Map.put(acc, field, value)}}
        else
          {:halt, :error}
        end

      _field, _acc ->
        {:halt, :error}
    end)
  end

  defp field_index(schema, field) do
    case Enum.find_index(schema, &(elem(&1, 0) == field)) do
      nil -> :error
      index -> {:ok, index + 1}
    end
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block(forms) do
    case Enum.reject(forms, &is_nil/1) do
      [form] -> form
      forms -> {:__block__, [], forms}
    end
  end
end
