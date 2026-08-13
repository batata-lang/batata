defmodule Batata.Frontend.GuardSupport do
  @moduledoc """
  Pure AST capability checks shared by frontend inventory and lifting.

  A positive result means the guard shape is understood. End-to-end semantic
  support still requires an executable lowering and BEAM-oracle gate.
  """

  @predicates [:is_integer, :is_float, :is_atom, :is_binary, :is_list, :is_tuple, :is_map]
  @boolean_operators [:and, :andalso, :or, :orelse]

  @spec supported?(Macro.t()) :: boolean()
  def supported?(guard_ast), do: do_supported?(guard_ast) and guard_bifs_protected?(guard_ast)

  defp do_supported?({predicate, _, [var_ast]}) when predicate in @predicates do
    match?(
      {name, _, context} when is_atom(name) and (is_atom(context) or is_nil(context)),
      var_ast
    )
  end

  defp do_supported?({op, _, [left, right]}) when op in [:==, :!=, :===, :!==],
    do: operand?(left) and operand?(right)

  defp do_supported?({op, _, [left, right]}) when op in [:<, :<=, :>, :>=],
    do: integer_expression?(left) and integer_expression?(right)

  defp do_supported?({:in, _, [{name, _, _}, members]}) when is_atom(name),
    do: integer_members(members) != nil

  defp do_supported?({op, _, [left, right]}) when op in @boolean_operators,
    do: do_supported?(left) and do_supported?(right)

  defp do_supported?(_guard_ast), do: false

  @spec integer_members(Macro.t()) :: {:range, integer(), integer()} | {:set, [integer()]} | nil
  def integer_members({:.., _, [first, last]}) when is_integer(first) and is_integer(last),
    do: {:range, first, last}

  def integer_members(values) when is_list(values) do
    if Enum.all?(values, &is_integer/1), do: {:set, Enum.uniq(values)}
  end

  def integer_members({:sigil_c, _, [{:<<>>, _, [value]}, []]}) when is_binary(value),
    do: {:set, value |> String.to_charlist() |> Enum.uniq()}

  def integer_members(_members), do: nil

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
