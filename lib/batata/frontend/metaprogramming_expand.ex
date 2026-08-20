defmodule Batata.Frontend.MetaprogrammingExpand do
  @moduledoc """
  Expands bounded module-level compile-time generation forms (`for` and `if`).

  Runs before definition normalization so generated function clauses are
  admitted to the canonical frontend boundary without losing clause structure.
  """

  @available_optional_modules MapSet.new()
  @available_functions MapSet.new([
                         {Application, :compile_env, 3},
                         {:erlang, :is_map_key, 2}
                       ])
  @max_generated_iterations 512
  @max_generated_integer_bits 4096

  alias Batata.Frontend.Literal

  @doc """
  Expands module-level `for` and `if` constructs within a `defmodule` AST.
  """
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:__block__, meta, forms}) do
    {:__block__, meta, expand_forms(forms)}
  end

  def expand({:defmodule, meta, [name, [do: body]]}) do
    expanded_body =
      body
      |> body_forms()
      |> expand_forms()
      |> wrap_body()

    {:defmodule, meta, [name, [do: expanded_body]]}
  end

  def expand({:defimpl, meta, arguments}) do
    {prefix, [[do: body]]} = Enum.split(arguments, length(arguments) - 1)

    expanded_body =
      body
      |> body_forms()
      |> expand_forms()
      |> wrap_body()

    {:defimpl, meta, prefix ++ [[do: expanded_body]]}
  end

  def expand(other), do: other

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: List.wrap(form)

  defp wrap_body([single]), do: single
  defp wrap_body(forms), do: {:__block__, [], forms}

  defp expand_forms(forms) do
    {expanded, _bindings} =
      Enum.map_reduce(forms, %{}, fn form, bindings ->
        form = substitute_unquotes(form, bindings)

        case expand_reduce_assignment(form) do
          {:ok, generated, name, value} ->
            {generated, Map.put(bindings, name, value)}

          :error ->
            {expand_form(form), bindings}
        end
      end)

    List.flatten(expanded)
  end

  defp expand_form({:for, _meta, [{:<-, _, [{var_name, _, nil}, collection]}, [do: body]]} = form)
       when is_atom(var_name) do
    case eval_collection(collection) do
      {:ok, items} when is_list(items) and items != [] ->
        Enum.flat_map(items, fn item ->
          body
          |> substitute_unquotes(%{var_name => item})
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

  defp expand_reduce_assignment(
         {:=, _meta,
          [
            {binding_name, _, nil},
            {{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _,
             [
               collection,
               initial,
               {:fn, _, [{:->, _, [[{item_name, _, nil}, {acc_name, _, nil}], body]}]}
             ]}
          ]}
       )
       when is_atom(binding_name) and is_atom(item_name) and is_atom(acc_name) do
    with {:ok, items} when items != [] <- eval_collection(collection),
         true <- length(items) <= @max_generated_iterations,
         {:ok, initial} when is_integer(initial) <- Literal.eval(initial),
         true <- generated_integer_in_bounds?(initial),
         [next_acc | reversed_templates] <- body |> body_forms() |> Enum.reverse(),
         templates when templates != [] <- Enum.reverse(reversed_templates),
         true <- Enum.all?(templates, &definition_form?/1),
         {:ok, generated, final_acc} <-
           expand_reduce_iterations(items, initial, item_name, acc_name, templates, next_acc) do
      {:ok, generated, binding_name, final_acc}
    else
      _ -> :error
    end
  end

  defp expand_reduce_assignment(_form), do: :error

  defp expand_reduce_iterations(items, initial, item_name, acc_name, templates, next_acc) do
    items
    |> Enum.reduce_while({:ok, [], initial}, fn item, {:ok, generated, acc} ->
      bindings = %{item_name => item, acc_name => acc}
      iteration_forms = Enum.map(templates, &substitute_unquotes(&1, bindings))

      case eval_integer_expr(next_acc, bindings) do
        {:ok, next_value} ->
          {:cont, {:ok, generated ++ iteration_forms, next_value}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, generated, final_acc} -> {:ok, generated, final_acc}
      :error -> :error
    end
  end

  defp definition_form?({kind, _, _}) when kind in [:def, :defp], do: true
  defp definition_form?(_form), do: false

  defp eval_integer_expr(value, _bindings) when is_integer(value), do: {:ok, value}

  defp eval_integer_expr({name, _, nil}, bindings) when is_atom(name) do
    case Map.fetch(bindings, name) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp eval_integer_expr({op, _, [left, right]}, bindings) when op in [:+, :-, :*] do
    with {:ok, left} <- eval_integer_expr(left, bindings),
         {:ok, right} <- eval_integer_expr(right, bindings),
         value <- apply_integer_op(op, left, right),
         true <- generated_integer_in_bounds?(value) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  defp eval_integer_expr(_expression, _bindings), do: :error

  defp apply_integer_op(:+, left, right), do: left + right
  defp apply_integer_op(:-, left, right), do: left - right
  defp apply_integer_op(:*, left, right), do: left * right

  defp generated_integer_in_bounds?(value) do
    value |> abs() |> Integer.digits(2) |> length() <= @max_generated_integer_bits
  end

  defp eval_collection(collection) do
    case Literal.eval(collection) do
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

  defp eval_condition({:and, _, [left, right]}) do
    with {:ok, left} <- eval_condition(left) do
      if left, do: eval_condition(right), else: {:ok, false}
    end
  end

  defp eval_condition({:or, _, [left, right]}) do
    with {:ok, left} <- eval_condition(left) do
      if left, do: {:ok, true}, else: eval_condition(right)
    end
  end

  defp eval_condition({{:., _, [{:__aliases__, _, [:Code]}, :ensure_loaded?]}, _, [module_ast]}) do
    case Literal.eval(module_ast) do
      {:ok, module} when is_atom(module) ->
        {:ok, MapSet.member?(@available_optional_modules, module)}

      _ ->
        :error
    end
  end

  defp eval_condition({:function_exported?, _, [module_ast, function, arity]})
       when is_atom(function) and is_integer(arity) do
    case Literal.eval(module_ast) do
      {:ok, module} when is_atom(module) ->
        {:ok, MapSet.member?(@available_functions, {module, function, arity})}

      _ ->
        :error
    end
  end

  defp eval_condition(other) do
    case Literal.eval(other) do
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
  defp eval_simple_expr(other), do: Literal.eval(other)

  defp substitute_unquotes(ast, bindings) do
    Macro.prewalk(ast, fn
      {:unquote, _meta, [{name, _, nil}]} = unquote_ast when is_atom(name) ->
        case Map.fetch(bindings, name) do
          {:ok, value} -> Macro.escape(value)
          :error -> unquote_ast
        end

      {name, meta, args} when is_atom(name) and is_list(args) ->
        {name, meta, args}

      other ->
        other
    end)
  end
end
