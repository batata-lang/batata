defmodule Batata.Signature do
  @moduledoc false

  alias Batata.Frontend

  @term_guards ~w(is_atom is_binary is_float is_function is_list is_map is_tuple)a
  @builtin_modes %{
    {Kernel, :length, 1} => [:term],
    {:erlang, :length, 1} => [:term],
    {Atom, :to_string, 1} => [:term],
    {Integer, :to_string, 2} => [:term, :scalar],
    {Enum, :flat_map, 2} => [:term, :term],
    {Enum, :into, 2} => [:term, :term],
    {Enum, :intersperse, 2} => [:term, :term],
    {Enum, :map, 2} => [:term, :term],
    {Map, :to_list, 1} => [:term],
    {:binary, :at, 2} => [:term, :scalar],
    {:binary, :copy, 1} => [:term],
    {:erlang, :binary_to_float, 1} => [:term],
    {:erlang, :float_to_binary, 2} => [:term, :term],
    {:erlang, :split_binary, 2} => [:term, :scalar],
    {:lists, :keyfind, 3} => [:term, :term, :term],
    {:lists, :reverse, 1} => [:term],
    {:lists, :reverse, 2} => [:term, :term]
  }

  defguardp is_variable_ast(name, context) when is_atom(name) and is_atom(context)

  def builtin_modes(module, function, arity),
    do: Map.get(@builtin_modes, {module, function, arity})

  def infer(definitions) do
    initial =
      Map.new(definitions, fn %Frontend.Definition{name: name, arity: arity, clauses: clauses} ->
        modes =
          cond do
            name == :__fn_dispatch and arity == 9 ->
              [:scalar | List.duplicate(:term, 8)]

            arity == 8 and String.contains?(Atom.to_string(name), "__enum_mapper_") ->
              List.duplicate(:term, 5) ++ List.duplicate(:scalar, 3)

            true ->
              pattern_modes(arity, clauses)
          end

        {{name, arity}, modes}
      end)
      |> merge_trailing_integer_pattern_modes(definitions)

    fixed_point(definitions, initial)
  end

  defp merge_trailing_integer_pattern_modes(modes, definitions) do
    Enum.reduce(definitions, modes, fn %Frontend.Definition{
                                         name: name,
                                         arity: arity,
                                         clauses: clauses
                                       },
                                       acc ->
      if Enum.any?(clauses, &trailing_integer_clause?/1) do
        required = pattern_modes(arity, clauses)
        Map.update!(acc, {name, arity}, &merge_modes(&1, required))
      else
        acc
      end
    end)
  end

  defp trailing_integer_clause?(%Frontend.Clause{patterns: [_first | tails]}) do
    Enum.any?(tails, fn
      integer when is_integer(integer) -> true
      {:-, _, [integer]} when is_integer(integer) -> true
      _pattern -> false
    end)
  end

  defp trailing_integer_clause?(_clause), do: false

  defp fixed_point(definitions, modes) do
    next =
      Enum.reduce(definitions, modes, fn definition, acc ->
        key = {definition.name, definition.arity}
        inferred = infer_definition(definition, acc)
        Map.update!(acc, key, &merge_modes(&1, inferred))
      end)

    if next == modes, do: modes, else: fixed_point(definitions, next)
  end

  defp infer_definition(%Frontend.Definition{arity: arity, clauses: clauses}, signatures) do
    Enum.reduce(clauses, List.duplicate(:scalar, arity), fn clause, acc ->
      names = Enum.map(clause.patterns, &plain_variable/1)

      uses =
        [clause.guard_ast, clause.body_ast]
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(acc, &infer_ast(&1, names, signatures, &2))

      merge_modes(acc, uses)
    end)
  end

  defp infer_ast(ast, names, signatures, modes) do
    {_ast, modes} =
      Macro.prewalk(ast, modes, &infer_node(&1, &2, names, signatures))

    modes
  end

  defp infer_node(
         {{:., _, [{name, _, context}, field]}, _, []} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context) and is_atom(field),
       do: {node, mark_name(modes, names, name)}

  defp infer_node(
         {{:., _, [{name, _, context}]}, _, args} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context) and is_list(args),
       do: {node, mark_name(modes, names, name)}

  defp infer_node(
         {:__term_apply__, _, [{name, _, context}, args]} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context) and is_list(args),
       do: {node, mark_name(modes, names, name)}

  defp infer_node({:|, _, values} = node, modes, names, _signatures)
       when is_list(values),
       do: {node, mark_term_values(modes, names, values)}

  defp infer_node(
         {:case, _, [{name, _, context}, [do: clauses]]} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context) and is_list(clauses) do
    modes =
      if Enum.any?(clauses, &term_case_clause?/1),
        do: mark_name(modes, names, name),
        else: modes

    {node, modes}
  end

  defp infer_node(
         {{:., _, [module_ast, function]}, _, args} = node,
         modes,
         names,
         _signatures
       )
       when is_atom(function) and is_list(args) do
    call_modes =
      case module_ref(module_ast) do
        {:ok, module} -> builtin_modes(module, function, length(args))
        :error -> nil
      end

    {node, mark_arguments(modes, names, args, call_modes)}
  end

  defp infer_node(
         {:__enum_call__, _, [kind, _pattern, {name, _, context}]} = node,
         modes,
         names,
         _signatures
       )
       when kind in [:map, :flat_map] and is_variable_ast(name, context) do
    {node, mark_name(modes, names, name)}
  end

  defp infer_node(
         {:^, _, [{name, _, context}]} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context),
       do: {node, mark_name(modes, names, name)}

  defp infer_node({name, _, args} = node, modes, names, signatures)
       when is_atom(name) and is_list(args) do
    call_modes =
      cond do
        name == :is_integer ->
          [:scalar]

        name in @term_guards ->
          [:term]

        Batata.Stdlib.class({Kernel, name, length(args)}) == :native_term ->
          List.duplicate(:term, length(args))

        true ->
          Map.get(signatures, {name, length(args)})
      end

    {node, mark_arguments(modes, names, args, call_modes)}
  end

  defp infer_node(node, modes, _names, _signatures), do: {node, modes}

  defp module_ref({:__aliases__, _, parts}) when is_list(parts) and parts != [] do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: :error
  end

  defp module_ref(module) when is_atom(module), do: {:ok, module}
  defp module_ref(_module), do: :error

  defp mark_arguments(modes, _names, _args, nil), do: modes

  defp mark_arguments(modes, names, args, call_modes) do
    args
    |> Enum.zip(call_modes)
    |> Enum.reduce(modes, fn
      {{name, _, context}, :term}, acc when is_variable_ast(name, context) ->
        mark_name(acc, names, name)

      _, acc ->
        acc
    end)
  end

  defp mark_name(modes, names, name) do
    names
    |> Enum.with_index()
    |> Enum.reduce(modes, fn
      {^name, index}, acc -> List.replace_at(acc, index, :term)
      _, acc -> acc
    end)
  end

  defp mark_term_values(modes, names, values) do
    Enum.reduce(values, modes, fn
      {name, _, context}, acc when is_variable_ast(name, context) ->
        mark_name(acc, names, name)

      _, acc ->
        acc
    end)
  end

  defp pattern_modes(arity, clauses) do
    Enum.reduce(clauses, List.duplicate(:scalar, arity), fn clause, acc ->
      clause.patterns
      |> Enum.with_index()
      |> Enum.map(fn
        {pattern, index} when index > 0 and is_integer(pattern) -> :term
        {pattern, _index} -> pattern_mode(pattern)
      end)
      |> merge_modes(acc)
    end)
  end

  defp pattern_mode(pattern), do: if(scalar_pattern?(pattern), do: :scalar, else: :term)

  defp plain_variable({name, _, context}) when is_variable_ast(name, context), do: name
  defp plain_variable(_pattern), do: nil

  defp term_case_clause?({:->, _, [args, _body]}) do
    case args do
      [{:when, _, [pattern, _guard]}] -> term_case_pattern?(pattern)
      [pattern] -> term_case_pattern?(pattern)
      _ -> false
    end
  end

  defp term_case_clause?(_clause), do: false

  defp term_case_pattern?(pattern),
    do: not (is_integer(pattern) or plain_variable(pattern) != nil)

  defp scalar_pattern?(pattern), do: is_integer(pattern) or plain_variable(pattern) != nil

  defp merge_modes(left, right) do
    Enum.zip_with(left, right, fn
      :term, _ -> :term
      _, :term -> :term
      _, _ -> :scalar
    end)
  end
end
