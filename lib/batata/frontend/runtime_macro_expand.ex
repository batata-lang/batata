defmodule Batata.Frontend.RuntimeMacroExpand do
  @moduledoc """
  Structurally normalizes two bounded runtime-producing macro shapes.

  A private macro using quote with bind_quoted and binding becomes an
  equivalent private function. A caller-context macro supplies separate
  normal and guard templates, substituted without host execution.
  """

  @type signature :: {atom(), non_neg_integer()}

  @doc "Normalizes supported runtime macro declarations and local calls."
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, metadata, [name_ast, [do: body]]}) do
    forms = body_forms(body)
    templates = caller_templates(forms)
    forms = Enum.flat_map(forms, &expand_form(&1, templates))

    {:defmodule, metadata, [name_ast, [do: block(forms)]]}
  end

  def expand(ast), do: ast

  defp caller_templates(forms) do
    Enum.reduce(forms, %{}, fn form, templates ->
      case caller_template(form) do
        {:ok, signature, template} -> Map.put(templates, signature, template)
        :error -> templates
      end
    end)
  end

  defp expand_form(form, templates) do
    case bind_quoted_function(form) do
      {:ok, function} ->
        [function]

      :error ->
        expand_non_binding_form(form, templates)
    end
  end

  defp expand_non_binding_form({:defmacro, _, [head]} = form, templates) do
    case definition_signature(head) do
      {:ok, signature} ->
        if Map.has_key?(templates, signature), do: [], else: [form]

      :error ->
        [form]
    end
  end

  defp expand_non_binding_form({:defmacro, _, [head, [do: _body]]} = form, templates) do
    case definition_signature(head) do
      {:ok, signature} ->
        if Map.has_key?(templates, signature), do: [], else: [form]

      :error ->
        [form]
    end
  end

  defp expand_non_binding_form({kind, metadata, [head, [do: body]]}, templates)
       when kind in [:def, :defp] do
    head = rewrite_definition_head(head, templates)
    body = rewrite_calls(body, :normal, templates)
    [{kind, metadata, [head, [do: body]]}]
  end

  defp expand_non_binding_form(form, _templates), do: [form]

  defp bind_quoted_function(
         {:defmacrop, metadata,
          [
            head,
            [
              do:
                {:quote, _,
                 [
                   [bind_quoted: {:binding, _, []}],
                   [do: body]
                 ]}
            ]
          ]}
       ) do
    case definition_signature(head) do
      {:ok, _signature} -> {:ok, {:defp, metadata, [head, [do: body]]}}
      :error -> :error
    end
  end

  defp bind_quoted_function(_form), do: :error

  defp caller_template({:defmacro, _, [head, [do: body]]}) do
    with {:ok, {name, arity}} <- definition_signature(head),
         {:ok, params} <- definition_params(head),
         {:ok, normal, guard} <- caller_context_templates(body) do
      {:ok, {name, arity}, %{params: params, normal: normal, guard: guard}}
    else
      _ -> :error
    end
  end

  defp caller_template(_form), do: :error

  defp caller_context_templates(
         {:case, _,
          [
            {{:., _, [{:__CALLER__, _, nil}, :context]}, _, []},
            [do: clauses]
          ]}
       )
       when is_list(clauses) do
    normal = quote_clause(clauses, nil)
    guard = quote_clause(clauses, :guard)

    if normal != :error and guard != :error,
      do: {:ok, normal, guard},
      else: :error
  end

  defp caller_context_templates(_body), do: :error

  defp quote_clause(clauses, context) do
    Enum.find_value(clauses, :error, fn
      {:->, _, [[^context], {:quote, _, [[do: quoted]]}]} -> quoted
      _clause -> nil
    end)
  end

  defp definition_signature({name, _, args}) when is_atom(name) and is_list(args),
    do: {:ok, {name, length(args)}}

  defp definition_signature(_head), do: :error

  defp definition_params({_name, _, args}) when is_list(args) do
    args
    |> Enum.reduce_while({:ok, []}, fn
      {name, _, nil}, {:ok, params} when is_atom(name) ->
        {:cont, {:ok, params ++ [name]}}

      _arg, _params ->
        {:halt, :error}
    end)
  end

  defp rewrite_definition_head({:when, metadata, heads_and_guard}, templates) do
    {heads, [guard]} = Enum.split(heads_and_guard, length(heads_and_guard) - 1)
    {:when, metadata, heads ++ [rewrite_calls(guard, :guard, templates)]}
  end

  defp rewrite_definition_head(head, _templates), do: head

  defp rewrite_calls(ast, context, templates) do
    Macro.postwalk(ast, fn
      {name, _, args} = call when is_atom(name) and is_list(args) ->
        expand_call(call, {name, length(args)}, args, context, templates)

      node ->
        node
    end)
  end

  defp expand_call(call, signature, args, context, templates) do
    case Map.fetch(templates, signature) do
      {:ok, template} ->
        bindings = template.params |> Enum.zip(args) |> Map.new()
        substitute_template(Map.fetch!(template, context), bindings)

      :error ->
        call
    end
  end

  defp substitute_template(ast, bindings) do
    Macro.prewalk(ast, fn
      {:unquote, _, [{name, _, nil}]} = unquote_ast when is_atom(name) ->
        Map.get(bindings, name, unquote_ast)

      node ->
        node
    end)
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block(forms) do
    case forms do
      [form] -> form
      forms -> {:__block__, [], forms}
    end
  end
end
