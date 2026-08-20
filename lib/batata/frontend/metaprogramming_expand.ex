defmodule Batata.Frontend.MetaprogrammingExpand do
  @moduledoc """
  Expands bounded module-level compile-time generation forms (`for` and `if`).

  Runs before definition normalization so generated function clauses are
  admitted to the canonical frontend boundary without losing clause structure.
  """

  @doc """
  Expands module-level `for` and `if` constructs within a `defmodule` AST.
  """
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, meta, [name, [do: body]]}) do
    expanded_body =
      body
      |> body_forms()
      |> expand_forms()
      |> wrap_body()

    {:defmodule, meta, [name, [do: expanded_body]]}
  end

  def expand(other), do: other

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: List.wrap(form)

  defp wrap_body([single]), do: single
  defp wrap_body(forms), do: {:__block__, [], forms}

  defp expand_forms(forms) do
    Enum.flat_map(forms, &expand_form/1)
  end

  defp expand_form({:for, _meta, [{:<-, _, [{var_name, _, nil}, collection]}, [do: body]]} = form)
       when is_atom(var_name) do
    case eval_collection(collection) do
      {:ok, items} when is_list(items) and items != [] ->
        Enum.flat_map(items, fn item ->
          body
          |> substitute_unquote(var_name, item)
          |> body_forms()
          |> expand_forms()
        end)

      _ ->
        [form]
    end
  end

  defp expand_form({:if, _meta, [condition, branches]} = form) when is_list(branches) do
    do_branch = Keyword.get(branches, :do)
    else_branch = Keyword.get(branches, :else)

    case eval_condition(condition) do
      {:ok, true} ->
        if do_branch != nil do
          do_branch |> body_forms() |> expand_forms()
        else
          []
        end

      {:ok, false} ->
        if else_branch != nil do
          else_branch |> body_forms() |> expand_forms()
        else
          []
        end

      :error ->
        [form]
    end
  end

  defp expand_form(form), do: [form]

  defp eval_collection(collection) do
    if Macro.quoted_literal?(collection) do
      {value, _} = Code.eval_quoted(collection)
      {:ok, value}
    else
      case collection do
        [_ | _] = list when is_list(list) ->
          eval_collection_items(list)

        {:__aliases__, _, _} = alias_ast ->
          {expanded, _} = Code.eval_quoted(alias_ast)
          {:ok, [expanded]}

        _ ->
          :error
      end
    end
  rescue
    _ -> :error
  end

  defp eval_collection_items(items) do
    if Enum.all?(items, &evaluable_item?/1) do
      {value, _} = Code.eval_quoted(items)
      {:ok, value}
    else
      :error
    end
  end

  defp evaluable_item?(item) do
    Macro.quoted_literal?(item) or match?({:__aliases__, _, _}, item) or is_atom(item) or
      is_number(item) or is_binary(item)
  end

  defp eval_condition(true), do: {:ok, true}
  defp eval_condition(false), do: {:ok, false}
  defp eval_condition(nil), do: {:ok, false}

  defp eval_condition({:==, _, [left, right]}) do
    with {:ok, left_val} <- eval_simple_expr(left),
         {:ok, right_val} <- eval_simple_expr(right) do
      {:ok, left_val == right_val}
    else
      _ -> :error
    end
  end

  defp eval_condition({:!=, _, [left, right]}) do
    with {:ok, left_val} <- eval_simple_expr(left),
         {:ok, right_val} <- eval_simple_expr(right) do
      {:ok, left_val != right_val}
    else
      _ -> :error
    end
  end

  defp eval_condition(other) do
    if Macro.quoted_literal?(other) do
      {val, _} = Code.eval_quoted(other)
      {:ok, val not in [false, nil]}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp eval_simple_expr({{:., _, [{:__aliases__, _, [:Version]}, :compare]}, _, [v1, v2]}) do
    with {:ok, s1} <- eval_simple_expr(v1),
         {:ok, s2} <- eval_simple_expr(v2),
         true <- is_binary(s1) and is_binary(s2) do
      {:ok, Version.compare(s1, s2)}
    else
      _ -> :error
    end
  end

  defp eval_simple_expr({{:., _, [{:__aliases__, _, [:System]}, :version]}, _, []}) do
    {:ok, System.version()}
  end

  defp eval_simple_expr(atom) when is_atom(atom), do: {:ok, atom}
  defp eval_simple_expr(number) when is_number(number), do: {:ok, number}
  defp eval_simple_expr(binary) when is_binary(binary), do: {:ok, binary}

  defp eval_simple_expr(other) do
    if Macro.quoted_literal?(other) do
      {val, _} = Code.eval_quoted(other)
      {:ok, val}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp substitute_unquote(ast, var_name, replacement_value) do
    replacement_ast = Macro.escape(replacement_value)

    Macro.prewalk(ast, fn
      {:unquote, _, [{^var_name, _, nil}]} ->
        replacement_ast

      {:unquote, _meta, [expr]} = unquote_ast ->
        case expr do
          {^var_name, _, nil} -> replacement_ast
          _ -> unquote_ast
        end

      {name, meta, args} when is_atom(name) and is_list(args) ->
        {name, meta, args}

      other ->
        other
    end)
  end
end
