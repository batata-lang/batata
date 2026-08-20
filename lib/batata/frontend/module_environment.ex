defmodule Batata.Frontend.ModuleEnvironment do
  @moduledoc """
  Applies a bounded, lexical module environment to parsed module bodies.

  Supported constant attributes are evaluated sequentially and substituted
  only when the same module reads them. Supported import declarations are
  consumed only when their module and option shape are explicitly allowlisted.
  Nested modules retain an independent environment.
  """

  alias Batata.Frontend.Literal

  @bitwise_signatures MapSet.new([
                        {:"~~~", 1},
                        {:&&&, 2},
                        {:|||, 2},
                        {:"^^^", 2},
                        {:<<<, 2},
                        {:>>>, 2},
                        {:bnot, 1},
                        {:band, 2},
                        {:bor, 2},
                        {:bxor, 2},
                        {:bsl, 2},
                        {:bsr, 2}
                      ])

  @doc "Expands supported attributes and imports in one lexical module."
  @spec expand(Macro.t()) :: Macro.t()
  def expand({:defmodule, metadata, [name_ast, [do: body]]}) do
    forms = body_forms(body)
    reads = attribute_reads(forms)

    {forms, _attributes} =
      Enum.map_reduce(forms, %{}, &expand_form(&1, &2, reads))

    {:defmodule, metadata, [name_ast, [do: block(forms)]]}
  end

  def expand(ast), do: ast

  defp expand_form({:@, _, _} = form, attributes, reads) do
    rewritten = rewrite(form, attributes)

    case attribute_declaration(rewritten) do
      {:ok, name, value_ast} ->
        expand_attribute(name, value_ast, rewritten, attributes, reads)

      :error ->
        {rewritten, attributes}
    end
  end

  defp expand_form({:import, _, _} = form, attributes, _reads) do
    if supported_import?(form), do: {nil, attributes}, else: {form, attributes}
  end

  defp expand_form(form, attributes, _reads), do: {rewrite(form, attributes), attributes}

  defp expand_attribute(name, value_ast, form, attributes, reads) do
    if MapSet.member?(reads, name) do
      expand_read_attribute(name, value_ast, form, attributes)
    else
      {form, attributes}
    end
  end

  defp expand_read_attribute(name, value_ast, form, attributes) do
    case Literal.eval_constant(value_ast) do
      {:ok, value} -> {nil, Map.put(attributes, name, value)}
      :error -> {form, Map.delete(attributes, name)}
    end
  end

  defp attribute_declaration({:@, _, [{name, _, [value]}]}) when is_atom(name),
    do: {:ok, name, value}

  defp attribute_declaration(_form), do: :error

  defp supported_import?({:import, _, [module_ast]}) do
    import_allowed?(module_ast, [])
  end

  defp supported_import?({:import, _, [module_ast, options]}) when is_list(options) do
    import_allowed?(module_ast, options)
  end

  defp supported_import?(_form), do: false

  defp import_allowed?(module_ast, options) do
    case Literal.eval(module_ast) do
      {:ok, Bitwise} -> bitwise_options?(options)
      {:ok, Kernel} -> kernel_except_options?(options)
      _ -> false
    end
  end

  defp bitwise_options?([]), do: true

  defp bitwise_options?([{kind, signatures}]) when kind in [:only, :except],
    do: signature_subset?(signatures, @bitwise_signatures)

  defp bitwise_options?(_options), do: false

  defp kernel_except_options?(except: signatures) do
    signature_list?(signatures)
  end

  defp kernel_except_options?(_options), do: false

  defp signature_subset?(signatures, allowed) do
    signature_list?(signatures) and
      Enum.all?(signatures, fn signature -> MapSet.member?(allowed, signature) end)
  end

  defp signature_list?(signatures) when is_list(signatures) do
    Enum.all?(signatures, fn
      {name, arity} when is_atom(name) and is_integer(arity) and arity >= 0 -> true
      _signature -> false
    end)
  end

  defp signature_list?(_signatures), do: false

  defp attribute_reads(forms) do
    Enum.reduce(forms, MapSet.new(), fn form, reads ->
      MapSet.union(reads, collect_attribute_reads(form))
    end)
  end

  defp collect_attribute_reads({kind, _, _}) when kind in [:defmodule, :defprotocol, :defimpl],
    do: MapSet.new()

  defp collect_attribute_reads({:@, _, [{name, _, nil}]}) when is_atom(name),
    do: MapSet.new([name])

  defp collect_attribute_reads(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> collect_attribute_reads()
  end

  defp collect_attribute_reads(values) when is_list(values) do
    Enum.reduce(values, MapSet.new(), fn value, reads ->
      MapSet.union(reads, collect_attribute_reads(value))
    end)
  end

  defp collect_attribute_reads(_other), do: MapSet.new()

  defp rewrite({kind, _, _} = ast, _attributes)
       when kind in [:defmodule, :defprotocol, :defimpl],
       do: ast

  defp rewrite({:@, _, [{name, _, nil}]} = ast, attributes) when is_atom(name) do
    case Map.fetch(attributes, name) do
      {:ok, value} -> Macro.escape(value)
      :error -> ast
    end
  end

  defp rewrite(tuple, attributes) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&rewrite(&1, attributes))
    |> List.to_tuple()
  end

  defp rewrite(values, attributes) when is_list(values),
    do: Enum.map(values, &rewrite(&1, attributes))

  defp rewrite(other, _attributes), do: other

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block(forms) do
    case Enum.reject(forms, &is_nil/1) do
      [form] -> form
      forms -> {:__block__, [], forms}
    end
  end
end
