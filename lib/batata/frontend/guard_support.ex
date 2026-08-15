defmodule Batata.Frontend.GuardSupport do
  @moduledoc """
  Pure AST capability checks shared by frontend inventory and lifting.

  A positive result means the guard shape is understood. End-to-end semantic
  support still requires an executable lowering and BEAM-oracle gate.
  """

  @predicates [:is_integer, :is_float, :is_atom, :is_binary, :is_list, :is_tuple, :is_map]
  @boolean_operators [:and, :andalso, :or, :orelse]

  @spec supported?(Macro.t()) :: boolean()
  def supported?(guard_ast),
    do: do_supported?(guard_ast, false) and guard_bifs_protected?(guard_ast)

  @doc "Returns whether the production compiler has an executable lowering for the guard."
  @spec compiler_supported?(Macro.t()) :: boolean()
  def compiler_supported?(guard_ast),
    do: do_supported?(guard_ast, true) and guard_bifs_protected?(guard_ast)

  defp do_supported?({predicate, _, [var_ast]}, _function_guards?)
       when predicate in @predicates do
    match?(
      {name, _, context} when is_atom(name) and (is_atom(context) or is_nil(context)),
      var_ast
    )
  end

  defp do_supported?({:is_function, _, [var_ast]}, true) do
    match?(
      {name, _, context} when is_atom(name) and (is_atom(context) or is_nil(context)),
      var_ast
    )
  end

  defp do_supported?({:is_function, _, [var_ast, arity]}, true)
       when is_integer(arity) and arity >= 0 and arity <= 4 do
    match?(
      {name, _, context} when is_atom(name) and (is_atom(context) or is_nil(context)),
      var_ast
    )
  end

  defp do_supported?({op, _, [left, right]}, _function_guards?)
       when op in [:==, :!=, :===, :!==],
       do: operand?(left) and operand?(right)

  defp do_supported?({op, _, [left, right]}, _function_guards?) when op in [:<, :<=, :>, :>=],
    do: integer_expression?(left) and integer_expression?(right)

  defp do_supported?({:in, _, [{name, _, _}, members]}, _function_guards?) when is_atom(name),
    do: term_members(members) != nil

  defp do_supported?({op, _, [left, right]}, function_guards?) when op in @boolean_operators,
    do: do_supported?(left, function_guards?) and do_supported?(right, function_guards?)

  defp do_supported?(_guard_ast, _function_guards?), do: false

  @type term_members ::
          {:integer_range, integer(), integer()}
          | {:integer_set, [integer()]}
          | {:atom_set, [atom()]}

  @spec term_members(Macro.t()) :: term_members() | nil
  def term_members({:.., _, [first, last]}) do
    with {:ok, first} <- integer_literal(first),
         {:ok, last} <- integer_literal(last) do
      {:integer_range, first, last}
    else
      _ -> nil
    end
  end

  def term_members(values) when is_list(values) do
    values = Enum.map(values, &term_literal/1)

    cond do
      Enum.all?(values, &match?({:integer, _}, &1)) ->
        {:integer_set, values |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}

      Enum.all?(values, &match?({:atom, _}, &1)) ->
        {:atom_set, values |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}

      true ->
        nil
    end
  end

  def term_members({:sigil_c, _, [{:<<>>, _, [value]}, []]}) when is_binary(value),
    do: {:integer_set, value |> String.to_charlist() |> Enum.uniq()}

  def term_members(_members), do: nil

  defp term_literal(value) when is_atom(value), do: {:atom, value}

  defp term_literal(value) do
    case integer_literal(value) do
      {:ok, integer} -> {:integer, integer}
      :error -> :error
    end
  end

  defp integer_literal(value) when is_integer(value), do: {:ok, value}
  defp integer_literal({:-, _, [value]}) when is_integer(value), do: {:ok, -value}
  defp integer_literal({:+, _, [value]}) when is_integer(value), do: {:ok, value}
  defp integer_literal(_value), do: :error

  @spec integer_members(Macro.t()) :: {:range, integer(), integer()} | {:set, [integer()]} | nil
  def integer_members(members) do
    case term_members(members) do
      {:integer_range, first, last} -> {:range, first, last}
      {:integer_set, integers} -> {:set, integers}
      _ -> nil
    end
  end

  defp operand?(value) when is_integer(value), do: true
  defp operand?(value) when is_binary(value), do: true
  defp operand?(value) when is_atom(value), do: true
  defp operand?(value) when is_list(value), do: Enum.all?(value, &operand?/1)

  defp operand?({:rem, _, [left, right]}),
    do: integer_expression?(left) and integer_expression?(right)

  defp operand?({:byte_size, _, [value]}), do: variable?(value)

  defp operand?({{:., _, [module, :byte_size]}, _, [value]}) when module in [:erlang, Kernel],
    do: variable?(value)

  defp operand?({{:., _, [{:__aliases__, _, [:Kernel]}, :rem]}, _, [left, right]}),
    do: integer_expression?(left) and integer_expression?(right)

  defp operand?({name, _, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp operand?({:<<>>, _, _}), do: true
  defp operand?({:%{}, _, _}), do: true
  defp operand?(tuple) when is_tuple(tuple) and tuple_size(tuple) != 3, do: true
  defp operand?(_value), do: false

  defp variable?({name, _, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp variable?(_value), do: false

  defp integer_expression?(value) when is_integer(value), do: true

  defp integer_expression?({name, _, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp integer_expression?({op, _, [left, right]}) when op in [:+, :-, :*],
    do: integer_expression?(left) and integer_expression?(right)

  defp integer_expression?(_expression), do: false

  defp guard_bifs_protected?(guard_ast),
    do: protected_guard_bifs?(guard_ast, MapSet.new())

  defp protected_guard_bifs?({op, _, [left, right]}, protected)
       when op in [:and, :andalso] do
    protected_guard_bifs?(left, protected) and
      protected_guard_bifs?(right, MapSet.union(protected, integer_predicate_vars(left)))
  end

  defp protected_guard_bifs?({op, _, [left, right]}, protected)
       when op in [:or, :orelse],
       do: protected_guard_bifs?(left, protected) and protected_guard_bifs?(right, protected)

  defp protected_guard_bifs?({:rem, _, args}, protected),
    do: MapSet.subset?(expression_vars(args), protected)

  defp protected_guard_bifs?(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :rem]}, _, args},
         protected
       ),
       do: MapSet.subset?(expression_vars(args), protected)

  defp protected_guard_bifs?(tuple, protected) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.all?(&protected_guard_bifs?(&1, protected))

  defp protected_guard_bifs?(list, protected) when is_list(list),
    do: Enum.all?(list, &protected_guard_bifs?(&1, protected))

  defp protected_guard_bifs?(_ast, _protected), do: true

  defp integer_predicate_vars(ast) do
    {_ast, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:is_integer, _, [{var, _, context}]} = node, vars
        when is_atom(var) and (is_atom(context) or is_nil(context)) ->
          {node, MapSet.put(vars, var)}

        node, vars ->
          {node, vars}
      end)

    vars
  end

  defp expression_vars(ast) do
    {_ast, vars} =
      Macro.prewalk(ast, MapSet.new(), fn
        {var, _, context} = node, vars
        when is_atom(var) and (is_atom(context) or is_nil(context)) ->
          {node, MapSet.put(vars, var)}

        node, vars ->
          {node, vars}
      end)

    vars
  end
end
