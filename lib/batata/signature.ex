defmodule Batata.Signature do
  @moduledoc false

  alias Batata.Frontend

  @term_guards ~w(is_atom is_binary is_float is_list is_map is_tuple)a
  @builtin_modes %{
    {:lists, :keyfind, 3} => [:term, :term, :term],
    {:lists, :reverse, 2} => [:term, :term]
  }

  def builtin_modes(module, function, arity),
    do: Map.get(@builtin_modes, {module, function, arity})

  def infer(definitions) do
    initial =
      Map.new(definitions, fn %Frontend.Definition{name: name, arity: arity, clauses: clauses} ->
        {{name, arity}, pattern_modes(arity, clauses)}
      end)

    fixed_point(definitions, initial)
  end

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
      Macro.prewalk(ast, modes, fn
        {{:., _, [module]}, _, args} = node, acc when is_atom(module) and is_list(args) ->
          call_modes =
            builtin_modes(module, call_name(node), length(args)) ||
              if(Batata.Stdlib.class({module, call_name(node), length(args)}) == :native_term,
                do: List.duplicate(:term, length(args))
              )

          {node, mark_arguments(acc, names, args, call_modes)}

        {name, _, args} = node, acc when is_atom(name) and is_list(args) ->
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

          {node, mark_arguments(acc, names, args, call_modes)}

        node, acc ->
          {node, acc}
      end)

    modes
  end

  defp call_name({{:., _, [_module, function]}, _, _args}), do: function

  defp mark_arguments(modes, _names, _args, nil), do: modes

  defp mark_arguments(modes, names, args, call_modes) do
    args
    |> Enum.zip(call_modes)
    |> Enum.reduce(modes, fn
      {{name, _, nil}, :term}, acc when is_atom(name) -> mark_name(acc, names, name)
      _, acc -> acc
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

  defp pattern_modes(arity, clauses) do
    Enum.reduce(clauses, List.duplicate(:scalar, arity), fn clause, acc ->
      clause.patterns
      |> Enum.map(&pattern_mode/1)
      |> merge_modes(acc)
    end)
  end

  defp pattern_mode(pattern), do: if(scalar_pattern?(pattern), do: :scalar, else: :term)

  defp plain_variable({name, _, nil}) when is_atom(name), do: name
  defp plain_variable(_pattern), do: nil

  defp scalar_pattern?(pattern), do: is_integer(pattern) or plain_variable(pattern) != nil

  defp merge_modes(left, right) do
    Enum.zip_with(left, right, fn
      :term, _ -> :term
      _, :term -> :term
      _, _ -> :scalar
    end)
  end
end
