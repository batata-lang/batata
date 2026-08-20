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
    case eval_literal(collection) do
      {:ok, %Range{} = range} -> {:ok, Enum.to_list(range)}
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, value} when is_atom(value) -> {:ok, [value]}
      _ -> :error
    end
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
    case eval_literal(other) do
      {:ok, value} -> {:ok, value not in [false, nil]}
      :error -> :error
    end
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
  defp eval_simple_expr(other), do: eval_literal(other)

  # This evaluator intentionally supports only data constructors needed by
  # bounded module generation. It never invokes quoted code or host macros.
  defp eval_literal(value)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: {:ok, value}

  defp eval_literal({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  defp eval_literal({:.., _, [first, last]}) do
    with {:ok, first} when is_integer(first) <- eval_literal(first),
         {:ok, last} when is_integer(last) <- eval_literal(last) do
      {:ok, first..last}
    else
      _ -> :error
    end
  end

  defp eval_literal({:{}, _, items}) when is_list(items) do
    with {:ok, values} <- eval_literals(items), do: {:ok, List.to_tuple(values)}
  end

  defp eval_literal({left, right}) do
    with {:ok, left} <- eval_literal(left),
         {:ok, right} <- eval_literal(right) do
      {:ok, {left, right}}
    else
      _ -> :error
    end
  end

  defp eval_literal({:%{}, _, pairs}) when is_list(pairs) do
    with {:ok, values} <- eval_literals(pairs), do: {:ok, Map.new(values)}
  end

  defp eval_literal(values) when is_list(values), do: eval_literals(values)
  defp eval_literal(_other), do: :error

  defp eval_literals(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case eval_literal(value) do
        {:ok, evaluated} -> {:cont, {:ok, [evaluated | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, evaluated} -> {:ok, Enum.reverse(evaluated)}
      :error -> :error
    end
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
