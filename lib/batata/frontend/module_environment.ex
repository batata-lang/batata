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

    environment = %{
      attributes: %{},
      bitwise: MapSet.new(),
      locals: local_signatures(forms)
    }

    {forms, _environment} =
      Enum.map_reduce(forms, environment, &expand_form(&1, &2, reads))

    {:defmodule, metadata, [name_ast, [do: block(forms)]]}
  end

  def expand(ast), do: ast

  defp expand_form({:@, _, _} = form, environment, reads) do
    rewritten = rewrite(form, environment)

    case attribute_declaration(rewritten) do
      {:ok, name, value_ast} ->
        expand_attribute(name, value_ast, rewritten, environment, reads)

      :error ->
        {rewritten, environment}
    end
  end

  defp expand_form({:import, _, _} = form, environment, _reads) do
    case supported_import(form) do
      {:ok, :bitwise, signatures} ->
        {nil, %{environment | bitwise: MapSet.difference(signatures, environment.locals)}}

      {:ok, :kernel} ->
        {nil, environment}

      :error ->
        {form, environment}
    end
  end

  defp expand_form(form, environment, _reads),
    do: {rewrite(form, environment), environment}

  defp expand_attribute(name, value_ast, form, environment, reads) do
    if MapSet.member?(reads, name) do
      expand_read_attribute(name, value_ast, form, environment)
    else
      {form, environment}
    end
  end

  defp expand_read_attribute(name, value_ast, form, environment) do
    case Literal.eval_constant(value_ast) do
      {:ok, value} ->
        {nil, put_in(environment, [:attributes, name], value)}

      :error ->
        {form, update_in(environment.attributes, &Map.delete(&1, name))}
    end
  end

  defp attribute_declaration({:@, _, [{name, _, [value]}]}) when is_atom(name),
    do: {:ok, name, value}

  defp attribute_declaration(_form), do: :error

  defp supported_import({:import, _, [module_ast]}) do
    import_allowed(module_ast, [])
  end

  defp supported_import({:import, _, [module_ast, options]}) when is_list(options) do
    import_allowed(module_ast, options)
  end

  defp supported_import(_form), do: :error

  defp import_allowed(module_ast, options) do
    case Literal.eval(module_ast) do
      {:ok, Bitwise} -> bitwise_import(options)
      {:ok, Kernel} -> if(kernel_except_options?(options), do: {:ok, :kernel}, else: :error)
      _ -> :error
    end
  end

  defp bitwise_import([]), do: {:ok, :bitwise, @bitwise_signatures}

  defp bitwise_import([{kind, signatures}]) when kind in [:only, :except] do
    if signature_subset?(signatures, @bitwise_signatures) do
      selected = MapSet.new(signatures)

      imported =
        if kind == :only,
          do: selected,
          else: MapSet.difference(@bitwise_signatures, selected)

      {:ok, :bitwise, imported}
    else
      :error
    end
  end

  defp bitwise_import(_options), do: :error

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

  defp rewrite({kind, _, _} = ast, _environment)
       when kind in [:defmodule, :defprotocol, :defimpl],
       do: ast

  defp rewrite({:@, _, [{name, _, nil}]} = ast, environment) when is_atom(name) do
    case Map.fetch(environment.attributes, name) do
      {:ok, value} -> Macro.escape(value)
      :error -> ast
    end
  end

  defp rewrite({name, metadata, arguments}, environment)
       when is_atom(name) and is_list(arguments) do
    arguments = Enum.map(arguments, &rewrite(&1, environment))

    if MapSet.member?(environment.bitwise, {name, length(arguments)}) do
      {{:., metadata, [Bitwise, name]}, metadata, arguments}
    else
      {name, metadata, arguments}
    end
  end

  defp rewrite(tuple, environment) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&rewrite(&1, environment))
    |> List.to_tuple()
  end

  defp rewrite(values, environment) when is_list(values),
    do: Enum.map(values, &rewrite(&1, environment))

  defp rewrite(other, _environment), do: other

  defp local_signatures(forms) do
    Enum.reduce(forms, MapSet.new(), fn
      {kind, _, [{:when, _, [head | _guards]} | _]}, signatures when kind in [:def, :defp] ->
        put_local_signature(signatures, head)

      {kind, _, [head | _]}, signatures when kind in [:def, :defp] ->
        put_local_signature(signatures, head)

      _form, signatures ->
        signatures
    end)
  end

  defp put_local_signature(signatures, {name, _, arguments})
       when is_atom(name) and is_list(arguments),
       do: MapSet.put(signatures, {name, length(arguments)})

  defp put_local_signature(signatures, _head), do: signatures

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp block(forms) do
    case Enum.reject(forms, &is_nil/1) do
      [form] -> form
      forms -> {:__block__, [], forms}
    end
  end
end
