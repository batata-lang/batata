defmodule Batata.Frontend.AliasExpand do
  @moduledoc """
  Deterministically expands lexical `alias` declarations in parsed modules.

  Expansion is deliberately syntax-only: it does not call `Macro.expand/2` or
  load referenced modules. Alias bindings affect only subsequent forms in the
  same module body, may be rebound, and never leak into nested modules.
  """

  @type aliases :: %{optional(atom()) => [atom()]}

  @doc "Expands supported aliases and `__MODULE__` references in one module."
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, metadata, [name_ast, [do: body]]}) do
    {:defmodule, metadata, [name_ast, [do: expand_body(body, name_ast)]]}
  end

  def expand(ast), do: ast

  @doc "Expands a lexical body against its effective module name."
  @spec expand_body(Macro.t(), module() | Macro.t()) :: Macro.t()
  def expand_body(body, module) do
    module_parts = module_parts(module)

    {forms, _aliases} =
      body
      |> body_forms()
      |> Enum.map_reduce(%{}, &expand_form(&1, &2, module_parts))

    block(forms)
  end

  @doc "Returns whether a declaration belongs to the supported syntax-only slice."
  @spec supported_declaration?(Macro.t()) :: boolean()
  def supported_declaration?(form) do
    match?({:ok, _bindings}, alias_bindings(form, %{}, [:CurrentModule]))
  end

  defp expand_form({:alias, _, _} = form, aliases, module_parts) do
    case alias_bindings(form, aliases, module_parts) do
      {:ok, bindings} -> {nil, Map.merge(aliases, bindings)}
      :unsupported -> {form, aliases}
    end
  end

  defp expand_form(form, aliases, module_parts) do
    {rewrite(form, aliases, module_parts), aliases}
  end

  defp alias_bindings({:alias, _, [target]}, aliases, module_parts) do
    target
    |> target_groups(aliases, module_parts)
    |> case do
      {:ok, groups} -> {:ok, Map.new(groups, &{List.last(&1), &1})}
      :unsupported -> :unsupported
    end
  end

  defp alias_bindings({:alias, _, [target, [as: {:__aliases__, _, [as]}]]}, aliases, module_parts)
       when is_atom(as) do
    case target_groups(target, aliases, module_parts) do
      {:ok, [parts]} -> {:ok, %{as => parts}}
      _ -> :unsupported
    end
  end

  defp alias_bindings(_form, _aliases, _module_parts), do: :unsupported

  defp target_groups({:__aliases__, _, parts}, aliases, module_parts) do
    case expand_parts(parts, aliases, module_parts) do
      {:ok, parts} -> {:ok, [parts]}
      :unsupported -> :unsupported
    end
  end

  defp target_groups(
         {{:., _, [{:__aliases__, _, base}, :{}]}, _, children},
         aliases,
         module_parts
       )
       when is_list(children) do
    with {:ok, base} <- expand_parts(base, aliases, module_parts) do
      children
      |> Enum.reduce_while({:ok, []}, &append_group(&1, &2, base, module_parts))
    end
  end

  defp target_groups(_target, _aliases, _module_parts), do: :unsupported

  defp append_group({:__aliases__, _, child}, {:ok, groups}, base, module_parts) do
    case literal_parts(child, module_parts) do
      {:ok, child} -> {:cont, {:ok, groups ++ [base ++ child]}}
      :unsupported -> {:halt, :unsupported}
    end
  end

  defp append_group(_child, _acc, _base, _module_parts), do: {:halt, :unsupported}

  defp expand_parts(parts, aliases, module_parts) do
    with {:ok, parts} <- literal_parts(parts, module_parts),
         true <- parts != [] do
      case parts do
        [first | rest] -> {:ok, Map.get(aliases, first, [first]) ++ rest}
      end
    else
      _ -> :unsupported
    end
  end

  defp literal_parts(parts, module_parts) when is_list(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn
      {:__MODULE__, _, _}, {:ok, acc} -> {:cont, {:ok, acc ++ module_parts}}
      part, {:ok, acc} when is_atom(part) -> {:cont, {:ok, acc ++ [part]}}
      _part, _acc -> {:halt, :unsupported}
    end)
  end

  defp rewrite(form, aliases, module_parts) do
    {form, _state} =
      Macro.traverse(
        form,
        0,
        fn
          {:defmodule, _, _} = node, depth ->
            {node, depth + 1}

          node, depth when depth > 0 ->
            {node, depth}

          {:__aliases__, metadata, parts} = node, 0 ->
            case expand_parts(parts, aliases, module_parts) do
              {:ok, expanded} -> {{:__aliases__, metadata, expanded}, 0}
              :unsupported -> {node, 0}
            end

          {:__MODULE__, metadata, _context}, 0 ->
            {{:__aliases__, metadata, module_parts}, 0}

          node, depth ->
            {node, depth}
        end,
        fn
          {:defmodule, _, _} = node, depth -> {node, depth - 1}
          node, depth -> {node, depth}
        end
      )

    form
  end

  defp module_parts({:__aliases__, _, parts}) do
    case literal_parts(parts, []) do
      {:ok, parts} -> parts
      :unsupported -> []
    end
  end

  defp module_parts(module) when is_atom(module) do
    module |> Module.split() |> Enum.map(&String.to_atom/1)
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block(forms) do
    case Enum.reject(forms, &is_nil/1) do
      [form] -> form
      forms -> {:__block__, [], forms}
    end
  end
end
