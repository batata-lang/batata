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
  @max_generated_binary_bytes 512

  alias Batata.Frontend.Literal

  @type table_generator :: {module(), atom(), 2 | 3}

  @doc "Discovers public, array-backed table builders without loading their modules."
  @spec discover_table_generators([String.t()]) :: MapSet.t(table_generator())
  def discover_table_generators(sources) when is_list(sources) do
    Enum.reduce(sources, MapSet.new(), fn source, registry ->
      {:ok, ast} = Code.string_to_quoted(source)
      discover_table_generators_ast(ast, registry)
    end)
  end

  @doc """
  Expands module-level `for` and `if` constructs within a `defmodule` AST.
  """
  @spec expand(Macro.t()) :: Macro.t()
  def expand(ast), do: expand(ast, MapSet.new())

  @doc false
  @spec expand(Macro.t(), MapSet.t(table_generator())) :: Macro.t()
  def expand({:__block__, meta, forms}, table_generators) do
    {:__block__, meta, expand_forms(forms, %{}, table_generators)}
  end

  def expand({:defmodule, meta, [name, [do: body]]}, table_generators) do
    expanded_body =
      body
      |> body_forms()
      |> expand_forms(%{}, table_generators)
      |> wrap_body()

    {:defmodule, meta, [name, [do: expanded_body]]}
  end

  def expand({:defimpl, meta, arguments}, table_generators) do
    {prefix, [[do: body]]} = Enum.split(arguments, length(arguments) - 1)

    expanded_body =
      body
      |> body_forms()
      |> expand_forms(%{}, table_generators)
      |> wrap_body()

    {:defimpl, meta, prefix ++ [[do: expanded_body]]}
  end

  def expand(other, _table_generators), do: other

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: List.wrap(form)

  defp wrap_body([single]), do: single
  defp wrap_body(forms), do: {:__block__, [], forms}

  defp expand_forms(forms, initial_bindings, table_generators) do
    {expanded, _bindings} =
      Enum.map_reduce(forms, initial_bindings, fn form, bindings ->
        form = substitute_unquotes(form, bindings)

        case expand_assignment(form, bindings, table_generators) do
          {:ok, generated, name, value} ->
            {generated, Map.put(bindings, name, value)}

          :error ->
            {expand_form(form, bindings, table_generators), bindings}
        end
      end)

    List.flatten(expanded)
  end

  defp expand_form(
         {:for, _meta, [{:<-, _, [{var_name, _, nil}, collection]}, [do: body]]} = form,
         bindings,
         table_generators
       )
       when is_atom(var_name) do
    case eval_collection(collection, bindings) do
      {:ok, items} when is_list(items) and items != [] ->
        Enum.flat_map(items, fn item ->
          body
          |> substitute_unquotes(%{var_name => item})
          |> body_forms()
          |> expand_forms(Map.put(bindings, var_name, item), table_generators)
        end)

      _ ->
        [persist_compile_bindings(form, bindings)]
    end
  end

  defp expand_form({:if, _meta, [condition, branches]} = form, bindings, table_generators)
       when is_list(branches) do
    do_branch = Keyword.get(branches, :do)
    else_branch = Keyword.get(branches, :else)

    case eval_condition(condition, bindings) do
      {:ok, true} ->
        if do_branch != nil do
          do_branch |> body_forms() |> expand_forms(bindings, table_generators)
        else
          []
        end

      {:ok, false} ->
        if else_branch != nil do
          else_branch |> body_forms() |> expand_forms(bindings, table_generators)
        else
          []
        end

      :error ->
        [persist_compile_bindings(form, bindings)]
    end
  end

  defp expand_form(
         {{:., _, [module_ast, operation]}, _, [collection, {:fn, _, clauses}]} = form,
         bindings,
         table_generators
       )
       when operation in [:map, :each] and is_list(clauses) do
    with {:ok, Enum} <- Literal.eval(module_ast),
         {:ok, items} when is_list(items) and items != [] <-
           eval_collection(collection, bindings, table_generators),
         true <- length(items) <= @max_generated_iterations,
         {:ok, generated} <-
           expand_generator_items(items, clauses, bindings, table_generators) do
      generated
    else
      _ -> [persist_compile_bindings(form, bindings)]
    end
  end

  defp expand_form(form, bindings, _table_generators),
    do: [persist_compile_bindings(form, bindings)]

  defp expand_generator_items(items, clauses, bindings, table_generators) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, generated} ->
      case select_generator_clause(item, clauses) do
        {:ok, item_bindings, body} ->
          expanded =
            body
            |> body_forms()
            |> expand_forms(Map.merge(bindings, item_bindings), table_generators)

          {:cont, {:ok, generated ++ expanded}}

        :error ->
          {:halt, :error}
      end
    end)
  end

  defp select_generator_clause(item, clauses) do
    Enum.find_value(clauses, :error, fn
      {:->, _, [[{:when, _, [pattern, guard]}], body]} ->
        with {:ok, bindings} <- match_generator_pattern(pattern, item),
             true <- eval_generator_guard(guard, bindings) do
          {:ok, bindings, body}
        else
          _ -> nil
        end

      {:->, _, [[pattern], body]} ->
        case match_generator_pattern(pattern, item) do
          {:ok, bindings} -> {:ok, bindings, body}
          :error -> nil
        end

      _ ->
        nil
    end)
  end

  defp match_generator_pattern({name, _, nil}, value) when is_atom(name) do
    if name == :_, do: {:ok, %{}}, else: {:ok, %{name => value}}
  end

  defp match_generator_pattern({:{}, _, patterns}, value)
       when is_list(patterns) and is_tuple(value) and tuple_size(value) == length(patterns) do
    patterns
    |> Enum.zip(Tuple.to_list(value))
    |> Enum.reduce_while({:ok, %{}}, fn {pattern, item}, {:ok, bindings} ->
      case match_generator_pattern(pattern, item) do
        {:ok, matched} -> {:cont, {:ok, Map.merge(bindings, matched)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp match_generator_pattern({left, right}, {left_value, right_value}) do
    with {:ok, left_bindings} <- match_generator_pattern(left, left_value),
         {:ok, right_bindings} <- match_generator_pattern(right, right_value) do
      {:ok, Map.merge(left_bindings, right_bindings)}
    end
  end

  defp match_generator_pattern(pattern, value) do
    case Literal.eval(pattern) do
      {:ok, ^value} -> {:ok, %{}}
      _ -> :error
    end
  end

  defp eval_generator_guard({name, _, [{variable, _, nil}]}, bindings)
       when name in [:is_atom, :is_binary, :is_integer, :is_list] do
    case Map.fetch(bindings, variable) do
      {:ok, value} -> generator_type?(name, value)
      :error -> false
    end
  end

  defp eval_generator_guard(_guard, _bindings), do: false

  defp generator_type?(:is_atom, value), do: is_atom(value)
  defp generator_type?(:is_binary, value), do: is_binary(value)
  defp generator_type?(:is_integer, value), do: is_integer(value)
  defp generator_type?(:is_list, value), do: is_list(value)

  defp expand_assignment(
         {:=, _meta, [{name, _, nil}, expression]} = form,
         bindings,
         table_generators
       )
       when is_atom(name) do
    case expand_reduce_assignment(form, bindings) do
      {:ok, generated, value} ->
        {:ok, generated, name, value}

      :error ->
        case eval_compile_expr(expression, bindings, table_generators) do
          {:ok, value} -> {:ok, [], name, value}
          :error -> :error
        end
    end
  end

  defp expand_assignment(_form, _bindings, _table_generators), do: :error

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

  defp eval_collection(collection, bindings, table_generators) do
    case eval_compile_expr(collection, bindings, table_generators) do
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

  defp eval_compile_expr({op, _, [left, right]}, bindings) when op in [:+, :-, :*] do
    eval_integer_expr({op, [], [left, right]}, bindings)
  end

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

  defp eval_compile_expr(
         {{:., _, [{:__aliases__, _, [:List]}, :to_string]}, _, [expression]},
         bindings
       ) do
    with {:ok, value} when is_list(value) <- eval_compile_expr(expression, bindings),
         true <- List.ascii_printable?(value) do
      {:ok, List.to_string(value)}
    else
      _ -> :error
    end
  end

  defp eval_compile_expr(
         {{:., _, [{:__aliases__, _, [:String]}, :duplicate]}, _, [binary_ast, count_ast]},
         bindings
       ) do
    with {:ok, binary} when is_binary(binary) <- eval_compile_expr(binary_ast, bindings),
         {:ok, count} when is_integer(count) and count >= 0 <-
           eval_compile_expr(count_ast, bindings),
         true <- byte_size(binary) * count <= @max_generated_binary_bytes do
      {:ok, String.duplicate(binary, count)}
    else
      _ -> :error
    end
  end

  defp eval_compile_expr(
         {{:., _, [:io_lib, :format]}, _, ["\\u~4.16.0B", [byte_ast]]},
         bindings
       ) do
    case eval_compile_expr(byte_ast, bindings) do
      {:ok, byte} when is_integer(byte) and byte >= 0 ->
        {:ok,
         ~c"\\u" ++
           (byte
            |> Integer.to_string(16)
            |> String.upcase()
            |> String.pad_leading(4, "0")
            |> String.to_charlist())}

      _ ->
        :error
    end
  end

  defp eval_compile_expr({:<<>>, _, segments}, bindings) when is_list(segments) do
    segments
    |> Enum.reduce_while({:ok, [], 0}, fn segment, {:ok, values, size} ->
      with {:ok, value, segment_size} <- eval_binary_segment(segment, bindings),
           true <- size + segment_size <= @max_generated_iterations do
        {:cont, {:ok, [value | values], size + segment_size}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values, _size} -> {:ok, values |> Enum.reverse() |> IO.iodata_to_binary()}
      :error -> :error
    end
  end

  defp eval_compile_expr([{:|, _, [head, tail]}], bindings),
    do: eval_compile_expr({:|, [], [head, tail]}, bindings)

  defp eval_compile_expr({:|, _, [head, tail]}, bindings) do
    with {:ok, head} <- eval_compile_expr(head, bindings),
         {:ok, tail} when is_list(tail) <- eval_compile_expr(tail, bindings),
         true <- length(tail) < @max_generated_iterations do
      {:ok, [head | tail]}
    else
      _ -> :error
    end
  end

  defp eval_compile_expr(values, bindings) when is_list(values) do
    case List.pop_at(values, -1) do
      {{:|, _, _} = tail, prefix} ->
        with {:ok, prefix} <- eval_proper_list(prefix, bindings),
             {:ok, tail} <- eval_compile_expr(tail, bindings),
             true <- length(prefix) + length(tail) <= @max_generated_iterations do
          {:ok, prefix ++ tail}
        else
          _ -> :error
        end

      _ ->
        eval_proper_list(values, bindings)
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

  defp eval_binary_segment({:"::", _, [expression, {:binary, _, nil}]}, bindings) do
    case eval_compile_expr(expression, bindings) do
      {:ok, value} when is_binary(value) -> {:ok, value, byte_size(value)}
      _ -> :error
    end
  end

  defp eval_binary_segment(segment, _bindings) when is_binary(segment),
    do: {:ok, segment, byte_size(segment)}

  defp eval_binary_segment(segment, bindings) do
    case eval_compile_expr(segment, bindings) do
      {:ok, value} when is_integer(value) and value in 0..255 -> {:ok, value, 1}
      _ -> :error
    end
  end

  defp eval_proper_list(values, bindings) do
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

  defp eval_compile_expr(expression, bindings, table_generators) do
    case table_generator_call(expression, bindings, table_generators) do
      {:ok, table} -> {:ok, table}
      :error -> eval_compile_expr(expression, bindings)
    end
  end

  defp table_generator_call(
         {{:., _, [module_ast, function]}, _, arguments},
         bindings,
         table_generators
       )
       when is_atom(function) and length(arguments) in [2, 3] do
    with {:ok, module} when is_atom(module) <- Literal.eval(module_ast),
         signature = {module, function, length(arguments)},
         true <- MapSet.member?(table_generators, signature),
         {:ok, values} <- eval_compile_arguments(arguments, bindings),
         {:ok, table} <- build_table(values) do
      {:ok, table}
    else
      _ -> :error
    end
  end

  defp table_generator_call(_expression, _bindings, _table_generators), do: :error

  defp eval_compile_arguments(arguments, bindings) do
    Enum.reduce_while(arguments, {:ok, []}, fn argument, {:ok, values} ->
      case eval_compile_expr(argument, bindings) do
        {:ok, value} -> {:cont, {:ok, [value | values]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp build_table([ranges, default]) when is_list(ranges) do
    with {:ok, entries} <- table_entries(ranges),
         max when is_integer(max) <- entries |> Map.keys() |> Enum.max(fn -> -1 end) do
      materialize_table(entries, default, max + 1)
    end
  end

  defp build_table([ranges, default, size])
       when is_list(ranges) and is_integer(size) and size >= 0 and
              size <= @max_generated_iterations do
    with {:ok, entries} <- table_entries(ranges),
         true <- Enum.all?(Map.keys(entries), &(&1 < size)) do
      materialize_table(entries, default, size)
    else
      _ -> :error
    end
  end

  defp build_table(_values), do: :error

  defp table_entries(ranges) do
    Enum.reduce_while(ranges, {:ok, %{}}, fn
      {key, value}, {:ok, entries} when is_integer(key) and key >= 0 ->
        {:cont, {:ok, Map.put(entries, key, value)}}

      {%Range{} = range, value}, {:ok, entries} ->
        if Enum.count(range) <= @max_generated_iterations and Enum.all?(range, &(&1 >= 0)) do
          {:cont, {:ok, Enum.reduce(range, entries, &Map.put(&2, &1, value))}}
        else
          {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp materialize_table(_entries, _default, 0), do: {:ok, []}

  defp materialize_table(entries, default, size)
       when size <= @max_generated_iterations do
    {:ok, Enum.map(0..(size - 1), &{&1, Map.get(entries, &1, default)})}
  end

  defp materialize_table(_entries, _default, _size), do: :error

  defp call_signature({{:., _, [module_ast, function]}, _, arguments})
       when is_atom(function) and is_list(arguments) do
    case Literal.eval(module_ast) do
      {:ok, module} when is_atom(module) -> {:ok, {module, function, length(arguments)}}
      _ -> :error
    end
  end

  defp call_signature(_call), do: :error

  defp discover_table_generators_ast({:__block__, _, forms}, registry) do
    Enum.reduce(forms, registry, &discover_table_generators_ast/2)
  end

  defp discover_table_generators_ast({:defmodule, _, [module_ast, [do: body]]}, registry) do
    case Literal.eval(module_ast) do
      {:ok, module} when is_atom(module) ->
        body
        |> body_forms()
        |> Enum.reduce(registry, &discover_table_generator(&1, &2, module))

      _ ->
        registry
    end
  end

  defp discover_table_generators_ast(_ast, registry), do: registry

  defp discover_table_generator(form, registry, module) do
    case table_generator_signature(form, module) do
      {:ok, signature} -> MapSet.put(registry, signature)
      :error -> registry
    end
  end

  defp table_generator_signature({:def, _, [{name, _, arguments}, [do: body]]}, module)
       when is_atom(name) and is_list(arguments) and length(arguments) in [2, 3] do
    calls = remote_calls(body)

    if MapSet.member?(calls, {:array, :from_orddict}) and
         MapSet.member?(calls, {:array, :to_orddict}) do
      {:ok, {module, name, length(arguments)}}
    else
      :error
    end
  end

  defp table_generator_signature(_form, _module), do: :error

  defp remote_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, MapSet.new(), fn
        {{:., _, [module_ast, function]}, _, arguments} = call, acc
        when is_atom(function) and is_list(arguments) ->
          case Literal.eval(module_ast) do
            {:ok, module} when is_atom(module) ->
              {call, MapSet.put(acc, {module, function})}

            _ ->
              {call, acc}
          end

        node, acc ->
          {node, acc}
      end)

    calls
  end

  defp persist_compile_bindings({:=, meta, [left, right]}, bindings),
    do: {:=, meta, [left, substitute_compile_values(right, bindings)]}

  defp persist_compile_bindings(
         {{:., dot_meta, [module, operation]}, call_meta, [collection, function]},
         bindings
       )
       when operation in [:map, :each] do
    {{:., dot_meta, [module, operation]}, call_meta,
     [substitute_compile_values(collection, bindings), function]}
  end

  defp persist_compile_bindings({:if, meta, [condition, branches]}, bindings),
    do: {:if, meta, [substitute_compile_values(condition, bindings), branches]}

  defp persist_compile_bindings(form, _bindings), do: form

  defp substitute_compile_values(ast, bindings) do
    Macro.prewalk(ast, fn
      {name, _, nil} = variable when is_atom(name) ->
        case Map.fetch(bindings, name) do
          {:ok, value} -> Macro.escape(value)
          :error -> variable
        end

      node ->
        node
    end)
  end

  defp substitute_unquotes(ast, bindings) do
    Macro.prewalk(ast, fn
      {:unquote, _meta, [expression]} = unquote_ast ->
        case eval_compile_expr(expression, bindings) do
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
