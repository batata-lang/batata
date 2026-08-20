defmodule Batata.Frontend.MetaprogrammingExpand do
  @moduledoc """
  Expands bounded module-level compile-time generation forms (`for` and `if`).

  Runs before definition normalization so generated function clauses are
  admitted to the canonical frontend boundary without losing clause structure.
  """

  @available_optional_modules MapSet.new()
  @available_functions MapSet.new([
                         {Application, :compile_env, 3},
                         {:erlang, :is_map_key, 2},
                         {:erlang, :float_to_binary, 2}
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

        case expand_assignment(form, bindings) do
          {:ok, generated, name, value} ->
            {generated, Map.put(bindings, name, value)}

          :error ->
            {expand_form(form, bindings), bindings}
        end
      end)

    List.flatten(expanded)
  end

  defp expand_form(
         {:for, _meta, [{:<-, _, [{var_name, _, nil}, collection]}, [do: body]]} = form,
         bindings
       )
       when is_atom(var_name) do
    case eval_collection(collection, bindings) do
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

  defp expand_form({:if, _meta, [condition, branches]} = form, bindings)
       when is_list(branches) do
    do_branch = Keyword.get(branches, :do)
    else_branch = Keyword.get(branches, :else)

    case eval_condition(condition, bindings) do
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

  defp expand_form(form, _bindings), do: [form]

  defp expand_assignment({:=, _meta, [{name, _, nil}, expression]} = form, bindings)
       when is_atom(name) do
    case expand_reduce_assignment(form, bindings) do
      {:ok, generated, value} ->
        {:ok, generated, name, value}

      :error ->
        case eval_compile_expr(expression, bindings) do
          {:ok, value} -> {:ok, [], name, value}
          :error -> :error
        end
    end
  end

  defp expand_assignment(_form, _bindings), do: :error

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
          ]},
         bindings
       )
       when is_atom(binding_name) and is_atom(item_name) and is_atom(acc_name) do
    with {:ok, items} when items != [] <- eval_collection(collection, bindings),
         true <- length(items) <= @max_generated_iterations,
         {:ok, initial} when is_integer(initial) <- Literal.eval(initial),
         true <- generated_integer_in_bounds?(initial),
         [next_acc | reversed_templates] <- body |> body_forms() |> Enum.reverse(),
         templates when templates != [] <- Enum.reverse(reversed_templates),
         true <- Enum.all?(templates, &definition_form?/1),
         {:ok, generated, final_acc} <-
           expand_reduce_iterations(items, initial, item_name, acc_name, templates, next_acc) do
      {:ok, generated, final_acc}
    else
      _ -> :error
    end
  end

  defp expand_reduce_assignment(_form, _bindings), do: :error

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

  defp eval_collection(collection, bindings) do
    case eval_compile_expr(collection, bindings) do
      {:ok, %Range{} = range} -> {:ok, Enum.to_list(range)}
      {:ok, value} when is_list(value) -> {:ok, value}
      {:ok, value} when is_atom(value) -> {:ok, [value]}
      _ -> :error
    end
  end

  defp eval_condition(condition, bindings)
  defp eval_condition(true, _bindings), do: {:ok, true}
  defp eval_condition(false, _bindings), do: {:ok, false}
  defp eval_condition(nil, _bindings), do: {:ok, false}

  defp eval_condition({:==, _, [left, right]}, bindings) do
    with {:ok, left_val} <- eval_simple_expr(left, bindings),
         {:ok, right_val} <- eval_simple_expr(right, bindings) do
      {:ok, left_val == right_val}
    else
      _ -> :error
    end
  end

  defp eval_condition({:!=, _, [left, right]}, bindings) do
    with {:ok, left_val} <- eval_simple_expr(left, bindings),
         {:ok, right_val} <- eval_simple_expr(right, bindings) do
      {:ok, left_val != right_val}
    else
      _ -> :error
    end
  end

  defp eval_condition({:and, _, [left, right]}, bindings) do
    with {:ok, left} <- eval_condition(left, bindings) do
      if left, do: eval_condition(right, bindings), else: {:ok, false}
    end
  end

  defp eval_condition({:or, _, [left, right]}, bindings) do
    with {:ok, left} <- eval_condition(left, bindings) do
      if left, do: {:ok, true}, else: eval_condition(right, bindings)
    end
  end

  defp eval_condition(
         {{:., _, [{:__aliases__, _, [:Code]}, :ensure_loaded?]}, _, [module_ast]},
         _bindings
       ) do
    case Literal.eval(module_ast) do
      {:ok, module} when is_atom(module) ->
        {:ok, MapSet.member?(@available_optional_modules, module)}

      _ ->
        :error
    end
  end

  defp eval_condition({:function_exported?, _, [module_ast, function, arity]}, _bindings)
       when is_atom(function) and is_integer(arity) do
    case Literal.eval(module_ast) do
      {:ok, module} when is_atom(module) ->
        {:ok, MapSet.member?(@available_functions, {module, function, arity})}

      _ ->
        :error
    end
  end

  defp eval_condition(other, bindings) do
    case eval_compile_expr(other, bindings) do
      {:ok, value} -> {:ok, value not in [false, nil]}
      :error -> :error
    end
  end

  defp eval_simple_expr(
         {{:., _, [{:__aliases__, _, [:Version]}, :compare]}, _, [v1, v2]},
         bindings
       ) do
    with {:ok, s1} <- eval_simple_expr(v1, bindings),
         {:ok, s2} <- eval_simple_expr(v2, bindings),
         true <- is_binary(s1) and is_binary(s2) do
      {:ok, Version.compare(s1, s2)}
    else
      _ -> :error
    end
  end

  defp eval_simple_expr(
         {{:., _, [{:__aliases__, _, [:System]}, :version]}, _, []},
         _bindings
       ) do
    {:ok, System.version()}
  end

  defp eval_simple_expr(other, bindings), do: eval_compile_expr(other, bindings)

  defp eval_compile_expr({name, _, nil}, bindings) when is_atom(name),
    do: Map.fetch(bindings, name)

  defp eval_compile_expr(
         {{:., _, [{:__aliases__, _, [:Enum]}, :zip]}, _, [left, right]},
         bindings
       ) do
    with {:ok, left} when is_list(left) <- eval_compile_expr(left, bindings),
         {:ok, right} when is_list(right) <- eval_compile_expr(right, bindings),
         true <- max(length(left), length(right)) <= @max_generated_iterations do
      {:ok, Enum.zip(left, right)}
    else
      _ -> :error
    end
  end

  defp eval_compile_expr({:sigil_c, _, [{:<<>>, _, [contents]}, []]}, _bindings)
       when is_binary(contents),
       do: {:ok, String.to_charlist(contents)}

  defp eval_compile_expr([{:|, _, [head, tail]}], bindings) do
    with {:ok, head} <- eval_compile_expr(head, bindings),
         {:ok, tail} when is_list(tail) <- eval_compile_expr(tail, bindings),
         true <- length(tail) < @max_generated_iterations do
      {:ok, [head | tail]}
    else
      _ -> :error
    end
  end

  defp eval_compile_expr(values, bindings) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case eval_compile_expr(value, bindings) do
        {:ok, evaluated} -> {:cont, {:ok, [evaluated | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, evaluated} -> {:ok, Enum.reverse(evaluated)}
      :error -> :error
    end
  end

  defp eval_compile_expr(
         {:try, _,
          [[do: call, catch: _catch_clauses, else: [{:->, _, [[{:_, _, nil}], value]}]]]},
         bindings
       ) do
    with {:ok, signature} <- call_signature(call),
         true <- MapSet.member?(@available_functions, signature) do
      eval_compile_expr(value, bindings)
    else
      _ -> :error
    end
  end

  defp eval_compile_expr(expression, _bindings), do: Literal.eval(expression)

  defp call_signature({{:., _, [module_ast, function]}, _, arguments})
       when is_atom(function) and is_list(arguments) do
    case Literal.eval(module_ast) do
      {:ok, module} when is_atom(module) -> {:ok, {module, function, length(arguments)}}
      _ -> :error
    end
  end

  defp call_signature(_call), do: :error

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
