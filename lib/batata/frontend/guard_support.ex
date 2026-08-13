defmodule Batata.Frontend.GuardSupport do
  @moduledoc """
  Pure AST capability checks shared by frontend inventory and lifting.

  A positive result means the guard shape is understood. End-to-end semantic
  support still requires an executable lowering and BEAM-oracle gate.
  """

  @predicates [:is_integer, :is_float, :is_atom, :is_binary, :is_list, :is_tuple, :is_map]
  @boolean_operators [:and, :andalso, :or, :orelse]

  @spec supported?(Macro.t()) :: boolean()
  def supported?({predicate, _, [var_ast]}) when predicate in @predicates do
    match?(
      {name, _, context} when is_atom(name) and (is_atom(context) or is_nil(context)),
      var_ast
    )
  end

  def supported?({op, _, [left, right]}) when op in [:==, :!=, :===, :!==],
    do: operand?(left) and operand?(right)

  def supported?({op, _, [left, right]}) when op in [:<, :<=, :>, :>=],
    do: integer_expression?(left) and integer_expression?(right)

  def supported?({:in, _, [{name, _, _}, members]}) when is_atom(name),
    do: integer_members(members) != nil

  def supported?({op, _, [left, right]}) when op in @boolean_operators,
    do: supported?(left) and supported?(right)

  def supported?(_guard_ast), do: false

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

  defp operand?({name, _, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp operand?({:<<>>, _, _}), do: true
  defp operand?({:%{}, _, _}), do: true
  defp operand?(tuple) when is_tuple(tuple) and tuple_size(tuple) != 3, do: true
  defp operand?(_value), do: false

  defp integer_expression?(value) when is_integer(value), do: true

  defp integer_expression?({name, _, context})
       when is_atom(name) and (is_atom(context) or is_nil(context)),
       do: true

  defp integer_expression?({op, _, [left, right]}) when op in [:+, :-, :*],
    do: integer_expression?(left) and integer_expression?(right)

  defp integer_expression?(_expression), do: false
end
