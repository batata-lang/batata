defmodule Batata.Signature do
  @moduledoc false

  alias Batata.Frontend

  @term_guards ~w(is_atom is_binary is_float is_function is_list is_map is_tuple)a
  @bitwise_signatures MapSet.new([
                        {Bitwise, :bnot, 1},
                        {Bitwise, :"~~~", 1},
                        {Bitwise, :band, 2},
                        {Bitwise, :bor, 2},
                        {Bitwise, :bxor, 2},
                        {Bitwise, :bsl, 2},
                        {Bitwise, :bsr, 2},
                        {Bitwise, :&&&, 2},
                        {Bitwise, :|||, 2},
                        {Bitwise, :"^^^", 2},
                        {Bitwise, :<<<, 2},
                        {Bitwise, :>>>, 2}
                      ])
  @builtin_modes %{
    {Kernel, :length, 1} => [:term],
    {:erlang, :length, 1} => [:term],
    {Atom, :to_string, 1} => [:term],
    {String, :to_atom, 1} => [:term],
    {String, :to_existing_atom, 1} => [:term],
    {Integer, :to_string, 2} => [:term, :scalar],
    {Enum, :flat_map, 2} => [:term, :term],
    {Enum, :into, 2} => [:term, :term],
    {Enum, :intersperse, 2} => [:term, :term],
    {Enum, :map, 2} => [:term, :term],
    {List, :duplicate, 2} => [:term, :scalar],
    {Map, :to_list, 1} => [:term],
    {:maps, :from_list, 1} => [:term],
    {String, :duplicate, 2} => [:term, :scalar],
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

  def builtin_modes(module, function, arity) do
    signature = {module, function, arity}

    if MapSet.member?(@bitwise_signatures, signature),
      do: List.duplicate(:scalar, arity),
      else: Map.get(@builtin_modes, signature)
  end

  @doc false
  def infer_integer_guards(definitions) do
    definitions
    |> Enum.group_by(&{&1.name, &1.arity})
    |> Map.new(fn {signature = {_name, arity}, grouped} ->
      clauses = Enum.flat_map(grouped, & &1.clauses)
      {signature, integer_guard_modes(arity, clauses)}
    end)
  end

  defp integer_guard_modes(0, _clauses), do: []

  defp integer_guard_modes(arity, clauses) do
    Enum.map(0..(arity - 1), fn index ->
      clauses != [] and Enum.all?(clauses, &integer_guarded_argument?(&1, index))
    end)
  end

  defp integer_guarded_argument?(clause, index) do
    case Enum.at(clause.patterns, index) do
      integer when is_integer(integer) ->
        true

      {name, _, context} when is_variable_ast(name, context) ->
        guard_requires_integer?(clause.guard_ast, name)

      _pattern ->
        false
    end
  end

  defp guard_requires_integer?(nil, _name), do: false

  defp guard_requires_integer?(guard_ast, name) do
    {_guard_ast, required?} =
      Macro.prewalk(guard_ast, false, fn
        {:is_integer, _, [{^name, _, context}]} = node, _required?
        when is_atom(context) ->
          {node, true}

        node, required? ->
          {node, required?}
      end)

    required?
  end

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

  @doc false
  def infer_results(definitions, no_return_functions \\ MapSet.new()) do
    groups = Enum.group_by(definitions, &{&1.name, &1.arity})
    infer_results_fixed_point(groups, no_return_functions, MapSet.new())
  end

  defp infer_results_fixed_point(groups, no_return_functions, proven) do
    next =
      Enum.reduce(groups, proven, fn {signature, definitions}, acc ->
        clauses = Enum.flat_map(definitions, & &1.clauses)

        if scalar_clauses?(clauses, acc, no_return_functions) do
          MapSet.put(acc, signature)
        else
          acc
        end
      end)

    if next == proven,
      do: proven,
      else: infer_results_fixed_point(groups, no_return_functions, next)
  end

  defp scalar_clauses?(clauses, proven, no_return_functions) do
    clauses != [] and
      Enum.all?(clauses, fn clause ->
        scalar_result?(
          clause.body_ast,
          proven,
          no_return_functions,
          scalar_clause_variables(clause)
        )
      end)
  end

  defp scalar_result?(ast, proven, no_return_functions, scalar_variables) do
    result_kind(ast, proven, no_return_functions, scalar_variables) == :scalar
  end

  defp result_kind(integer, _proven, _no_return_functions, _scalar_variables)
       when is_integer(integer),
       do: :scalar

  defp result_kind({:-, _, [integer]}, _proven, _no_return_functions, _scalar_variables)
       when is_integer(integer),
       do: :scalar

  defp result_kind({:__block__, _, expressions}, proven, no_return_functions, scalar_variables)
       when expressions != [],
       do:
         expressions
         |> List.last()
         |> result_kind(proven, no_return_functions, scalar_variables)

  defp result_kind(
         {:case, _, [_value, [do: clauses]]},
         proven,
         no_return_functions,
         scalar_variables
       )
       when is_list(clauses) do
    clauses
    |> Enum.map(&clause_result_kind(&1, proven, no_return_functions, scalar_variables))
    |> combine_result_kinds()
  end

  defp result_kind(
         {:if, _, [condition, branches]},
         proven,
         no_return_functions,
         scalar_variables
       )
       when is_list(branches) do
    with true <- scalar_condition?(condition, proven, no_return_functions, scalar_variables),
         {:ok, then_branch} <- Keyword.fetch(branches, :do),
         {:ok, else_branch} <- Keyword.fetch(branches, :else) do
      [
        result_kind(then_branch, proven, no_return_functions, scalar_variables),
        result_kind(else_branch, proven, no_return_functions, scalar_variables)
      ]
      |> combine_result_kinds()
    else
      _not_proven -> :unknown
    end
  end

  defp result_kind({:throw, _, [_value]}, _proven, _no_return_functions, _scalar_variables),
    do: :no_return

  defp result_kind({name, _, context}, _proven, _no_return_functions, scalar_variables)
       when is_variable_ast(name, context) do
    if MapSet.member?(scalar_variables, name), do: :scalar, else: :unknown
  end

  defp result_kind({name, _, arguments}, proven, no_return_functions, scalar_variables)
       when is_atom(name) and is_list(arguments) do
    signature = {name, length(arguments)}

    cond do
      MapSet.member?(no_return_functions, signature) ->
        :no_return

      MapSet.member?(proven, signature) ->
        :scalar

      name in [:+, :-, :*, :div, :rem] and
          Enum.all?(arguments, fn argument ->
            result_kind(argument, proven, no_return_functions, scalar_variables) == :scalar
          end) ->
        :scalar

      true ->
        :unknown
    end
  end

  defp result_kind(
         {{:., _, [module_ast, function]}, _, arguments},
         proven,
         no_return_functions,
         scalar_variables
       )
       when is_atom(function) and is_list(arguments) do
    with {:ok, module} <- module_ref(module_ast),
         modes when is_list(modes) <- builtin_modes(module, function, length(arguments)),
         true <- Enum.all?(modes, &(&1 == :scalar)),
         true <-
           Enum.all?(arguments, fn argument ->
             result_kind(argument, proven, no_return_functions, scalar_variables) == :scalar
           end) do
      :scalar
    else
      _not_scalar -> :unknown
    end
  end

  defp result_kind(_ast, _proven, _no_return_functions, _scalar_variables), do: :unknown

  defp clause_result_kind(
         {:->, _, [_patterns, body]},
         proven,
         no_return_functions,
         scalar_variables
       ),
       do: result_kind(body, proven, no_return_functions, scalar_variables)

  defp clause_result_kind(_clause, _proven, _no_return_functions, _scalar_variables),
    do: :unknown

  defp guarded_scalar_variables(nil), do: MapSet.new()

  defp guarded_scalar_variables(guard_ast) do
    {_guard_ast, variables} =
      Macro.prewalk(guard_ast, MapSet.new(), fn
        {:is_integer, _, [{name, _, context}]} = node, variables
        when is_variable_ast(name, context) ->
          {node, MapSet.put(variables, name)}

        node, variables ->
          {node, variables}
      end)

    variables
  end

  defp scalar_clause_variables(clause) do
    [clause.guard_ast, clause.body_ast]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(MapSet.new(), fn ast, variables ->
      MapSet.union(variables, scalar_operation_variables(ast))
    end)
    |> MapSet.union(guarded_scalar_variables(clause.guard_ast))
  end

  defp scalar_operation_variables(ast) do
    {_ast, variables} =
      Macro.prewalk(ast, MapSet.new(), fn
        {operator, _, arguments} = node, variables
        when operator in [:+, :-, :*, :div, :rem, :<, :>, :<=, :>=] and is_list(arguments) ->
          {node, Enum.reduce(arguments, variables, &put_scalar_variable/2)}

        {{:., _, [module_ast, function]}, _, arguments} = node, variables
        when is_atom(function) and is_list(arguments) ->
          scalar? =
            case module_ref(module_ast) do
              {:ok, module} ->
                builtin_modes(module, function, length(arguments)) ==
                  List.duplicate(:scalar, length(arguments))

              :error ->
                false
            end

          if scalar?,
            do: {node, Enum.reduce(arguments, variables, &put_scalar_variable/2)},
            else: {node, variables}

        node, variables ->
          {node, variables}
      end)

    variables
  end

  defp put_scalar_variable({name, _, context}, variables)
       when is_variable_ast(name, context),
       do: MapSet.put(variables, name)

  defp put_scalar_variable(_argument, variables), do: variables

  defp scalar_condition?(
         {operator, _, [left, right]},
         proven,
         no_return_functions,
         scalar_variables
       )
       when operator in [:==, :!=, :<, :>, :<=, :>=] do
    Enum.all?([left, right], fn operand ->
      result_kind(operand, proven, no_return_functions, scalar_variables) == :scalar
    end)
  end

  defp scalar_condition?(_condition, _proven, _no_return_functions, _scalar_variables),
    do: false

  defp combine_result_kinds(kinds) do
    cond do
      kinds == [] -> :unknown
      Enum.all?(kinds, &(&1 == :no_return)) -> :no_return
      Enum.all?(kinds, &(&1 in [:scalar, :no_return])) -> :scalar
      true -> :unknown
    end
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
         {:if, _, [{name, _, context}, _branches]} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context),
       do: {node, mark_name(modes, names, name)}

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
