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
    {Kernel, :abs, 1} => [:scalar],
    {Kernel, :max, 2} => [:scalar, :scalar],
    {Kernel, :min, 2} => [:scalar, :scalar],
    {Kernel, :binary_part, 3} => [:term, :scalar, :scalar],
    {:erlang, :length, 1} => [:term],
    {:erlang, :binary_part, 3} => [:term, :scalar, :scalar],
    {:lists, :split, 2} => [:scalar, :term],
    {:lists, :duplicate, 2} => [:scalar, :term],
    {Atom, :to_string, 1} => [:term],
    {String, :to_atom, 1} => [:term],
    {String, :to_existing_atom, 1} => [:term],
    {Integer, :to_string, 2} => [:term, :scalar],
    {Enum, :flat_map, 2} => [:term, :term],
    {Enum, :find, 2} => [:term, :term],
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
    {:io_lib_format, :fwrite_g, 1} => [:term],
    {:erlang, :split_binary, 2} => [:term, :scalar],
    {:lists, :keyfind, 3} => [:term, :term, :term],
    {:lists, :reverse, 1} => [:term],
    {:lists, :reverse, 2} => [:term, :term],
    {Date, :to_iso8601, 1} => [:term],
    {DateTime, :to_iso8601, 1} => [:scalar],
    {NaiveDateTime, :to_iso8601, 1} => [:scalar],
    {Time, :to_iso8601, 1} => [:scalar]
  }
  @builtin_scalar_results MapSet.new([
                            {Kernel, :length, 1},
                            {:erlang, :length, 1}
                          ])
  @min_scalar_integer -9_223_372_036_854_775_808
  @max_scalar_integer 9_223_372_036_854_775_807

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
    returned_closures = returned_closure_names(definitions)

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

    fixed_point(definitions, initial, returned_closures)
  end

  @doc false
  def infer_results(definitions, no_return_functions \\ MapSet.new()) do
    groups = Enum.group_by(definitions, &{&1.name, &1.arity})
    returned_closures = returned_closure_names(definitions)
    infer_results_fixed_point(groups, no_return_functions, returned_closures, MapSet.new())
  end

  @doc false
  def infer_integer_results(definitions, no_return_functions \\ MapSet.new()) do
    groups = Enum.group_by(definitions, &{&1.name, &1.arity})
    infer_integer_results_fixed_point(groups, no_return_functions, MapSet.new())
  end

  @doc false
  def infer_boolean_results(definitions, no_return_functions \\ MapSet.new()) do
    # Start from every local signature and remove contradictions. This
    # greatest fixed point admits recursive cycles only while every returning
    # clause remains structurally boolean; a mixed term return removes the
    # entire dependent cycle on subsequent iterations. A second, least fixed
    # point then requires a concrete boolean-producing path, so pure recursion
    # and no-return-only functions are not assigned a scalar result ABI.
    groups = Enum.group_by(definitions, &{&1.name, &1.arity})
    candidates = groups |> Map.keys() |> MapSet.new()

    safe = infer_boolean_results_fixed_point(groups, no_return_functions, candidates)
    infer_productive_boolean_results(groups, safe, MapSet.new())
  end

  @doc false
  def infer_boolean_arguments(definitions, boolean_result_functions \\ MapSet.new()) do
    groups = Enum.group_by(definitions, &{&1.name, &1.arity})

    private_signatures =
      groups
      |> Enum.filter(fn {_signature, grouped} ->
        Enum.all?(grouped, &(&1.kind == :defp))
      end)
      |> Map.new(fn {signature = {_name, arity}, _grouped} ->
        {signature, List.duplicate(false, arity)}
      end)

    calls = collect_local_calls(definitions, Map.keys(groups) |> MapSet.new())

    infer_boolean_arguments_fixed_point(
      private_signatures,
      calls,
      boolean_result_functions,
      %{}
    )
  end

  defp infer_boolean_arguments_fixed_point(candidates, calls, boolean_results, proven) do
    next =
      Map.new(candidates, fn candidate ->
        infer_boolean_argument_modes(candidate, calls, proven, boolean_results)
      end)

    if next == proven,
      do: proven,
      else: infer_boolean_arguments_fixed_point(candidates, calls, boolean_results, next)
  end

  defp infer_boolean_argument_modes(
         {signature = {_name, arity}, empty_modes},
         calls,
         proven,
         boolean_results
       ) do
    callsites = Map.get(calls, signature, [])

    modes =
      if callsites == [] or arity == 0,
        do: empty_modes,
        else: boolean_callsite_modes(arity, callsites, proven, boolean_results)

    {signature, modes}
  end

  defp boolean_callsite_modes(arity, callsites, proven, boolean_results) do
    Enum.map(0..(arity - 1), fn index ->
      Enum.all?(callsites, fn {caller, clause, arguments} ->
        arguments
        |> Enum.at(index)
        |> boolean_argument_ast?(caller, clause, proven, boolean_results)
      end)
    end)
  end

  defp collect_local_calls(definitions, local_signatures) do
    Enum.reduce(definitions, %{}, fn definition, calls ->
      collect_definition_local_calls(definition, calls, local_signatures)
    end)
  end

  defp collect_definition_local_calls(definition, calls, local_signatures) do
    caller = {definition.name, definition.arity}

    Enum.reduce(definition.clauses, calls, fn clause, acc ->
      collect_clause_local_calls(clause, caller, acc, local_signatures)
    end)
  end

  defp collect_clause_local_calls(clause, caller, calls, local_signatures) do
    [clause.guard_ast, clause.body_ast]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(calls, fn ast, acc ->
      collect_ast_local_calls(ast, caller, clause, acc, local_signatures)
    end)
  end

  defp collect_ast_local_calls(ast, caller, clause, calls, local_signatures) do
    {_ast, calls} =
      Macro.prewalk(ast, calls, fn node, acc ->
        collect_local_call(node, caller, clause, acc, local_signatures)
      end)

    calls
  end

  defp collect_local_call(
         {callee, _, arguments} = node,
         caller,
         clause,
         calls,
         local_signatures
       )
       when is_atom(callee) and is_list(arguments) do
    signature = {callee, length(arguments)}

    calls =
      if MapSet.member?(local_signatures, signature),
        do:
          Map.update(
            calls,
            signature,
            [{caller, clause, arguments}],
            &[{caller, clause, arguments} | &1]
          ),
        else: calls

    {node, calls}
  end

  defp collect_local_call(node, _caller, _clause, calls, _local_signatures), do: {node, calls}

  defp boolean_argument_ast?(value, _caller, _clause, _proven, _boolean_results)
       when value in [true, false],
       do: true

  defp boolean_argument_ast?(
         {operator, _, [_left, _right]},
         _caller,
         _clause,
         _proven,
         _boolean_results
       )
       when operator in [:==, :!=, :===, :!==, :<, :<=, :>, :>=, :in],
       do: true

  defp boolean_argument_ast?(
         {name, _, [_argument]},
         _caller,
         _clause,
         _proven,
         _boolean_results
       )
       when name in [:is_atom, :is_binary, :is_list, :is_tuple, :is_map, :is_integer, :is_float],
       do: true

  defp boolean_argument_ast?(
         {operator, _, [left, right]},
         caller,
         clause,
         proven,
         boolean_results
       )
       when operator in [:and, :or] do
    boolean_argument_ast?(left, caller, clause, proven, boolean_results) and
      boolean_argument_ast?(right, caller, clause, proven, boolean_results)
  end

  defp boolean_argument_ast?(
         {name, _, arguments},
         _caller,
         _clause,
         _proven,
         boolean_results
       )
       when is_atom(name) and is_list(arguments),
       do: MapSet.member?(boolean_results, {name, length(arguments)})

  defp boolean_argument_ast?(
         {name, _, context},
         caller,
         clause,
         proven,
         _boolean_results
       )
       when is_variable_ast(name, context) do
    index = Enum.find_index(clause.patterns, &(plain_variable(&1) == name))
    index != nil and proven |> Map.get(caller, []) |> Enum.at(index, false)
  end

  defp boolean_argument_ast?(_ast, _caller, _clause, _proven, _boolean_results), do: false

  defp infer_boolean_results_fixed_point(groups, no_return_functions, candidates) do
    next =
      Enum.reduce(groups, candidates, fn {signature, definitions}, acc ->
        if safe_boolean_definitions?(definitions, candidates, no_return_functions) do
          acc
        else
          MapSet.delete(acc, signature)
        end
      end)

    if next == candidates,
      do: candidates,
      else: infer_boolean_results_fixed_point(groups, no_return_functions, next)
  end

  defp safe_boolean_definitions?(definitions, candidates, no_return_functions) do
    clauses = Enum.flat_map(definitions, & &1.clauses)

    clauses != [] and
      Enum.all?(clauses, fn clause ->
        boolean_result_kind(clause.body_ast, candidates, no_return_functions) in [
          :boolean,
          :no_return
        ]
      end)
  end

  defp infer_productive_boolean_results(groups, safe, productive) do
    next =
      Enum.reduce(groups, productive, fn {signature, definitions}, acc ->
        if MapSet.member?(safe, signature) and
             productive_boolean_definitions?(definitions, productive) do
          MapSet.put(acc, signature)
        else
          acc
        end
      end)

    if next == productive,
      do: productive,
      else: infer_productive_boolean_results(groups, safe, next)
  end

  defp productive_boolean_definitions?(definitions, productive) do
    definitions
    |> Enum.flat_map(& &1.clauses)
    |> Enum.any?(&productive_boolean_result?(&1.body_ast, productive))
  end

  defp productive_boolean_result?({:__block__, _, expressions}, productive)
       when expressions != [],
       do: expressions |> List.last() |> productive_boolean_result?(productive)

  defp productive_boolean_result?({:case, _, [_value, [do: clauses]]}, productive)
       when is_list(clauses) do
    Enum.any?(clauses, fn
      {:->, _, [_patterns, body]} -> productive_boolean_result?(body, productive)
      _clause -> false
    end)
  end

  defp productive_boolean_result?({:if, _, [_condition, branches]}, productive)
       when is_list(branches) do
    branches
    |> Keyword.take([:do, :else])
    |> Keyword.values()
    |> Enum.any?(&productive_boolean_result?(&1, productive))
  end

  defp productive_boolean_result?({:cond, _, [[do: clauses]]}, productive)
       when is_list(clauses) do
    Enum.any?(clauses, fn
      {:->, _, [_conditions, body]} -> productive_boolean_result?(body, productive)
      _clause -> false
    end)
  end

  defp productive_boolean_result?({operator, _, [_left, _right]}, _productive)
       when operator in [:==, :!=, :===, :!==, :<, :<=, :>, :>=, :in],
       do: true

  defp productive_boolean_result?({operator, _, [left, right]}, productive)
       when operator in [:and, :or],
       do:
         productive_boolean_result?(left, productive) or
           productive_boolean_result?(right, productive)

  defp productive_boolean_result?({name, _, [_argument]}, _productive)
       when name in [:is_atom, :is_binary, :is_list, :is_tuple, :is_map, :is_integer, :is_float],
       do: true

  defp productive_boolean_result?({name, _, arguments}, productive)
       when is_atom(name) and is_list(arguments),
       do: MapSet.member?(productive, {name, length(arguments)})

  defp productive_boolean_result?(_ast, _productive), do: false

  defp boolean_result_kind({:__block__, _, expressions}, candidates, no_return_functions)
       when expressions != [],
       do: expressions |> List.last() |> boolean_result_kind(candidates, no_return_functions)

  defp boolean_result_kind(
         {:case, _, [_value, [do: clauses]]},
         candidates,
         no_return_functions
       )
       when is_list(clauses) do
    clauses
    |> Enum.map(fn
      {:->, _, [_patterns, body]} ->
        boolean_result_kind(body, candidates, no_return_functions)

      _clause ->
        :unknown
    end)
    |> combine_boolean_result_kinds()
  end

  defp boolean_result_kind({:if, _, [_condition, branches]}, candidates, no_return_functions)
       when is_list(branches) do
    with {:ok, then_branch} <- Keyword.fetch(branches, :do),
         {:ok, else_branch} <- Keyword.fetch(branches, :else) do
      [
        boolean_result_kind(then_branch, candidates, no_return_functions),
        boolean_result_kind(else_branch, candidates, no_return_functions)
      ]
      |> combine_boolean_result_kinds()
    else
      _missing_branch -> :unknown
    end
  end

  defp boolean_result_kind({:cond, _, [[do: clauses]]}, candidates, no_return_functions)
       when is_list(clauses) do
    clauses
    |> Enum.map(fn
      {:->, _, [_conditions, body]} ->
        boolean_result_kind(body, candidates, no_return_functions)

      _clause ->
        :unknown
    end)
    |> combine_boolean_result_kinds()
  end

  defp boolean_result_kind({operator, _, [_left, _right]}, _candidates, _no_return_functions)
       when operator in [:==, :!=, :===, :!==, :<, :<=, :>, :>=, :in],
       do: :boolean

  defp boolean_result_kind({operator, _, [left, right]}, candidates, no_return_functions)
       when operator in [:and, :or] do
    [
      boolean_result_kind(left, candidates, no_return_functions),
      boolean_result_kind(right, candidates, no_return_functions)
    ]
    |> combine_boolean_result_kinds()
  end

  defp boolean_result_kind({name, _, [_argument]}, _candidates, _no_return_functions)
       when name in [:is_atom, :is_binary, :is_list, :is_tuple, :is_map, :is_integer, :is_float],
       do: :boolean

  defp boolean_result_kind({:throw, _, [_value]}, _candidates, _no_return_functions),
    do: :no_return

  defp boolean_result_kind({:__batata_raise__, _, [_kind, _reason]}, _candidates, _no_return),
    do: :no_return

  defp boolean_result_kind({:__batata_raise__, _kind, _reason}, _candidates, _no_return),
    do: :no_return

  defp boolean_result_kind({:__batata_raise_scalar__, _kind, _reason}, _candidates, _no_return),
    do: :no_return

  defp boolean_result_kind({name, _, arguments}, candidates, no_return_functions)
       when is_atom(name) and is_list(arguments) do
    signature = {name, length(arguments)}

    cond do
      MapSet.member?(no_return_functions, signature) -> :no_return
      MapSet.member?(candidates, signature) -> :boolean
      true -> :unknown
    end
  end

  defp boolean_result_kind(_ast, _candidates, _no_return_functions), do: :unknown

  defp combine_boolean_result_kinds(kinds) do
    cond do
      kinds == [] -> :unknown
      Enum.all?(kinds, &(&1 == :no_return)) -> :no_return
      Enum.all?(kinds, &(&1 in [:boolean, :no_return])) -> :boolean
      true -> :unknown
    end
  end

  defp infer_results_fixed_point(groups, no_return_functions, returned_closures, proven) do
    next =
      Enum.reduce(groups, proven, fn {signature, definitions}, acc ->
        clauses = Enum.flat_map(definitions, & &1.clauses)

        identity? = closure_identity_result?(signature, clauses)

        if scalar_clauses?(clauses, acc, no_return_functions) or
             (identity? and not MapSet.member?(returned_closures, elem(signature, 0))) do
          MapSet.put(acc, signature)
        else
          acc
        end
      end)

    if next == proven,
      do: proven,
      else: infer_results_fixed_point(groups, no_return_functions, returned_closures, next)
  end

  defp infer_integer_results_fixed_point(groups, no_return_functions, proven) do
    next =
      Enum.reduce(groups, proven, fn {signature, definitions}, acc ->
        clauses = Enum.flat_map(definitions, & &1.clauses)

        if integer_clauses?(clauses, acc, no_return_functions),
          do: MapSet.put(acc, signature),
          else: acc
      end)

    if next == proven,
      do: proven,
      else: infer_integer_results_fixed_point(groups, no_return_functions, next)
  end

  defp integer_clauses?(clauses, proven, no_return_functions) do
    clauses != [] and
      Enum.all?(clauses, fn clause ->
        integer_result_kind(
          clause.body_ast,
          proven,
          no_return_functions,
          guarded_scalar_variables(clause.guard_ast)
        ) in [:integer, :no_return]
      end)
  end

  defp integer_result_kind(integer, _proven, _no_return_functions, _integer_variables)
       when is_integer(integer),
       do: :integer

  defp integer_result_kind(
         {:-, _, [integer]},
         _proven,
         _no_return_functions,
         _integer_variables
       )
       when is_integer(integer),
       do: :integer

  defp integer_result_kind(
         {:__block__, _, expressions},
         proven,
         no_return_functions,
         integer_variables
       )
       when expressions != [],
       do:
         expressions
         |> List.last()
         |> integer_result_kind(proven, no_return_functions, integer_variables)

  defp integer_result_kind(
         {:case, _, [_value, [do: clauses]]},
         proven,
         no_return_functions,
         integer_variables
       )
       when is_list(clauses) do
    clauses
    |> Enum.map(fn
      {:->, _, [_patterns, body]} ->
        integer_result_kind(body, proven, no_return_functions, integer_variables)

      _clause ->
        :unknown
    end)
    |> combine_integer_result_kinds()
  end

  defp integer_result_kind(
         {:if, _, [_condition, branches]},
         proven,
         no_return_functions,
         integer_variables
       )
       when is_list(branches) do
    with {:ok, then_branch} <- Keyword.fetch(branches, :do),
         {:ok, else_branch} <- Keyword.fetch(branches, :else) do
      [then_branch, else_branch]
      |> Enum.map(&integer_result_kind(&1, proven, no_return_functions, integer_variables))
      |> combine_integer_result_kinds()
    else
      _missing_branch -> :unknown
    end
  end

  defp integer_result_kind(
         {:cond, _, [[do: clauses]]},
         proven,
         no_return_functions,
         integer_variables
       )
       when is_list(clauses) do
    clauses
    |> Enum.map(fn
      {:->, _, [_conditions, body]} ->
        integer_result_kind(body, proven, no_return_functions, integer_variables)

      _clause ->
        :unknown
    end)
    |> combine_integer_result_kinds()
  end

  defp integer_result_kind({:throw, _, [_value]}, _proven, _no_return, _integer_variables),
    do: :no_return

  defp integer_result_kind(
         {:__batata_raise__, _, [_kind, _reason]},
         _proven,
         _no_return,
         _integer_variables
       ),
       do: :no_return

  defp integer_result_kind({name, _, context}, _proven, _no_return, integer_variables)
       when is_variable_ast(name, context) do
    if MapSet.member?(integer_variables, name), do: :integer, else: :unknown
  end

  defp integer_result_kind({operator, _, arguments}, proven, no_return, _integer_variables)
       when operator in [:+, :-, :*, :div, :rem] and is_list(arguments) do
    signature = {operator, length(arguments)}

    cond do
      MapSet.member?(no_return, signature) -> :no_return
      MapSet.member?(proven, signature) -> :integer
      length(arguments) == 2 -> :integer
      true -> :unknown
    end
  end

  defp integer_result_kind({name, _, arguments}, proven, no_return, _integer_variables)
       when is_atom(name) and is_list(arguments) do
    signature = {name, length(arguments)}

    cond do
      MapSet.member?(no_return, signature) -> :no_return
      MapSet.member?(proven, signature) -> :integer
      true -> :unknown
    end
  end

  defp integer_result_kind(_ast, _proven, _no_return, _integer_variables), do: :unknown

  defp combine_integer_result_kinds(kinds) do
    cond do
      kinds == [] -> :unknown
      Enum.all?(kinds, &(&1 == :no_return)) -> :no_return
      Enum.all?(kinds, &(&1 in [:integer, :no_return])) -> :integer
      true -> :unknown
    end
  end

  defp closure_identity_result?({name, _arity}, clauses) do
    String.starts_with?(Atom.to_string(name), "__fn_") and
      Enum.any?(clauses, &identity_clause?/1)
  end

  defp identity_clause?(%{body_ast: {result, _, context}, patterns: patterns})
       when is_atom(result) and (is_atom(context) or is_nil(context)),
       do: Enum.any?(patterns, &identity_pattern?(&1, result))

  defp identity_clause?(_clause), do: false

  defp identity_pattern?({result, _, context}, result)
       when is_atom(context) or is_nil(context),
       do: true

  defp identity_pattern?(_pattern, _result), do: false

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
       when is_integer(integer) do
    if scalar_integer?(integer), do: :scalar, else: :term
  end

  defp result_kind({:-, _, [integer]}, _proven, _no_return_functions, _scalar_variables)
       when is_integer(integer) do
    if scalar_integer?(-integer), do: :scalar, else: :term
  end

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

  defp result_kind(
         {:cond, _, [[do: clauses]]},
         proven,
         no_return_functions,
         scalar_variables
       )
       when is_list(clauses) do
    clauses
    |> Enum.map(&clause_result_kind(&1, proven, no_return_functions, scalar_variables))
    |> combine_result_kinds()
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
    case module_ref(module_ast) do
      {:ok, module} ->
        builtin_result_kind(
          module,
          function,
          arguments,
          proven,
          no_return_functions,
          scalar_variables
        )

      :error ->
        :unknown
    end
  end

  defp result_kind(_ast, _proven, _no_return_functions, _scalar_variables), do: :unknown

  defp builtin_result_kind(
         module,
         function,
         arguments,
         proven,
         no_return_functions,
         scalar_variables
       ) do
    signature = {module, function, length(arguments)}

    cond do
      MapSet.member?(@builtin_scalar_results, signature) ->
        :scalar

      builtin_scalar_arguments?(
        signature,
        arguments,
        proven,
        no_return_functions,
        scalar_variables
      ) ->
        :scalar

      true ->
        :unknown
    end
  end

  defp builtin_scalar_arguments?(
         {module, function, arity},
         arguments,
         proven,
         no_return_functions,
         scalar_variables
       ) do
    builtin_modes(module, function, arity) == List.duplicate(:scalar, arity) and
      Enum.all?(arguments, fn argument ->
        result_kind(argument, proven, no_return_functions, scalar_variables) == :scalar
      end)
  end

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

  defp fixed_point(definitions, modes, returned_closures) do
    next =
      Enum.reduce(definitions, modes, fn definition, acc ->
        key = {definition.name, definition.arity}
        inferred = infer_definition(definition, acc, returned_closures)
        Map.update!(acc, key, &merge_modes(&1, inferred))
      end)

    next = propagate_term_call_modes(definitions, next)

    if next == modes, do: modes, else: fixed_point(definitions, next, returned_closures)
  end

  defp propagate_term_call_modes(definitions, modes) do
    Enum.reduce(definitions, modes, fn definition, acc ->
      caller_modes = Map.fetch!(modes, {definition.name, definition.arity})

      if definition.name == :__fn_dispatch do
        acc
      else
        propagate_definition_calls(definition, caller_modes, acc)
      end
    end)
  end

  defp propagate_definition_calls(definition, caller_modes, modes) do
    Enum.reduce(definition.clauses, modes, fn clause, clause_modes ->
      names = Enum.map(clause.patterns, &plain_variable/1)

      [clause.guard_ast, clause.body_ast]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(clause_modes, &propagate_ast_calls(&1, &2, names, caller_modes))
    end)
  end

  defp propagate_ast_calls(ast, modes, names, caller_modes) do
    {_ast, modes} =
      Macro.prewalk(ast, modes, fn
        {callee, _, arguments} = node, current
        when is_atom(callee) and is_list(arguments) ->
          {node, promote_local_call_modes(current, callee, arguments, names, caller_modes)}

        node, current ->
          {node, current}
      end)

    modes
  end

  defp promote_local_call_modes(modes, callee, arguments, names, caller_modes) do
    signature = {callee, length(arguments)}

    if Map.has_key?(modes, signature) do
      required = Enum.map(arguments, &caller_argument_mode(&1, names, caller_modes))

      Map.update!(modes, signature, &merge_modes(&1, required))
    else
      modes
    end
  end

  defp caller_argument_mode(argument, names, caller_modes) do
    if caller_term_argument?(argument, names, caller_modes) or term_call_argument?(argument),
      do: :term,
      else: :scalar
  end

  defp term_call_argument?(value) when is_binary(value) or is_atom(value) or is_list(value),
    do: true

  defp term_call_argument?(value) when is_integer(value), do: not scalar_integer?(value)

  defp term_call_argument?({:-, _, [value]}) when is_integer(value),
    do: not scalar_integer?(-value)

  defp term_call_argument?({:{}, _, values}) when is_list(values), do: true
  defp term_call_argument?({:%{}, _, entries}) when is_list(entries), do: true
  defp term_call_argument?({:fn, _, clauses}) when is_list(clauses), do: true
  defp term_call_argument?({:__fn_ref__, _, _arguments}), do: true
  defp term_call_argument?(_argument), do: false

  defp caller_term_argument?({name, _, context}, names, caller_modes)
       when is_variable_ast(name, context) do
    case Enum.find_index(names, &(&1 == name)) do
      nil -> false
      index -> Enum.at(caller_modes, index) == :term
    end
  end

  defp caller_term_argument?(_argument, _names, _caller_modes), do: false

  defp infer_definition(
         %Frontend.Definition{name: name, arity: arity, clauses: clauses},
         signatures,
         returned_closures
       ) do
    Enum.reduce(clauses, List.duplicate(:scalar, arity), fn clause, acc ->
      names = Enum.map(clause.patterns, &plain_variable/1)

      uses =
        [clause.guard_ast, clause.body_ast]
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(acc, &infer_ast(&1, names, signatures, &2))

      uses =
        maybe_mark_closure_identity_result(
          name,
          clause.body_ast,
          names,
          uses,
          returned_closures
        )

      merge_modes(acc, uses)
    end)
  end

  # Extracted closures cross `__fn_dispatch` as term words. When a closure
  # returns one of its parameters unchanged there is no use-site operation
  # from which ordinary signature inference can recover that representation.
  # Keep that slot as a term; arithmetic closures still infer scalar modes
  # from their operators and retain the existing raw-i64 fast path.
  defp maybe_mark_closure_identity_result(
         name,
         {result, _, context},
         names,
         modes,
         returned_closures
       )
       when is_atom(name) and is_atom(result) and
              (is_atom(context) or is_nil(context)) do
    if MapSet.member?(returned_closures, name) do
      mark_name(modes, names, result)
    else
      modes
    end
  end

  defp maybe_mark_closure_identity_result(
         _name,
         _body,
         _names,
         modes,
         _returned_closures
       ),
       do: modes

  defp returned_closure_names(definitions) do
    Enum.reduce(definitions, MapSet.new(), fn %Frontend.Definition{clauses: clauses}, names ->
      Enum.reduce(clauses, names, fn clause, acc ->
        MapSet.union(acc, terminal_closure_names(clause.body_ast))
      end)
    end)
  end

  defp terminal_closure_names({:__fn_ref__, _, [_index, name, _arity, _captured]})
       when is_atom(name),
       do: MapSet.new([name])

  defp terminal_closure_names({:__block__, _, expressions}) when expressions != [],
    do: expressions |> List.last() |> terminal_closure_names()

  defp terminal_closure_names({:case, _, [_value, [do: clauses]]}) when is_list(clauses) do
    Enum.reduce(clauses, MapSet.new(), fn
      {:->, _, [_patterns, body]}, acc -> MapSet.union(acc, terminal_closure_names(body))
      _clause, acc -> acc
    end)
  end

  defp terminal_closure_names({:if, _, [_condition, branches]}) when is_list(branches) do
    branches
    |> Keyword.values()
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, terminal_closure_names(&1)))
  end

  defp terminal_closure_names(_ast), do: MapSet.new()

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
       do: {node, modes |> mark_name(names, name) |> mark_term_values(names, args)}

  defp infer_node(
         {:__term_apply__, _, [{name, _, context}, args]} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context) and is_list(args),
       do: {node, modes |> mark_name(names, name) |> mark_term_values(names, args)}

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
         {:=, _, [pattern, {name, _, context}]} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context) do
    modes = if pattern_mode(pattern) == :term, do: mark_name(modes, names, name), else: modes
    {node, modes}
  end

  defp infer_node({:%{}, _, entries} = node, modes, names, _signatures)
       when is_list(entries) do
    values =
      Enum.flat_map(entries, fn
        {key, value} -> [key, value]
        {:|, _, [base, updates]} -> [base, updates]
        other -> [other]
      end)

    {node, mark_term_values(modes, names, values)}
  end

  defp infer_node(
         {:if, _, [{name, _, context}, _branches]} = node,
         modes,
         names,
         _signatures
       )
       when is_variable_ast(name, context),
       do: {node, mark_name(modes, names, name)}

  defp infer_node({:in, _, [member, collection]} = node, modes, names, _signatures) do
    {node, mark_term_values(modes, names, [member, collection])}
  end

  defp infer_node({operator, _, [left, right]} = node, modes, names, _signatures)
       when operator in [:==, :!=, :===, :!==] do
    modes =
      modes
      |> then(fn acc ->
        if term_call_argument?(left), do: mark_term_values(acc, names, [right]), else: acc
      end)
      |> then(fn acc ->
        if term_call_argument?(right), do: mark_term_values(acc, names, [left]), else: acc
      end)

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
        {:ok, module} ->
          builtin_modes(module, function, length(args)) ||
            if(Batata.Stdlib.class({module, function, length(args)}) == :native_term,
              do: List.duplicate(:term, length(args))
            )

        :error ->
          nil
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
    kernel_modes = builtin_modes(Kernel, name, length(args))

    call_modes =
      cond do
        name == :is_integer ->
          [:scalar]

        name in @term_guards ->
          [:term]

        kernel_modes != nil ->
          kernel_modes

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

  defp term_case_pattern?(pattern), do: not scalar_pattern?(pattern)

  defp scalar_pattern?(pattern) when is_integer(pattern), do: scalar_integer?(pattern)
  defp scalar_pattern?(pattern), do: plain_variable(pattern) != nil

  defp scalar_integer?(integer),
    do: integer >= @min_scalar_integer and integer <= @max_scalar_integer

  defp merge_modes(left, right) do
    Enum.zip_with(left, right, fn
      :term, _ -> :term
      _, :term -> :term
      _, _ -> :scalar
    end)
  end
end
