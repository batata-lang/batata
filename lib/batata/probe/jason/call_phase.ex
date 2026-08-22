defmodule Batata.Probe.Jason.CallPhase do
  @moduledoc """
  Classifies remote corpus calls without executing source or expanding macros.

  Inputs must already have lexical aliases expanded. Calls made while a module
  body or macro body executes are compile-time edges. Calls emitted inside a
  quoted body are runtime edges, while their `unquote` expressions remain
  compile-time edges.
  """

  @type phase :: :compile_time | :runtime
  @type signature :: {atom(), non_neg_integer()}
  @type call :: {String.t(), signature(), phase()}

  @definition_kinds [:def, :defp]
  @macro_kinds [:defmacro, :defmacrop]
  @container_kinds [:defmodule, :defimpl, :defprotocol]

  @doc "Collects remote calls and their execution phase from normalized forms."
  @spec collect(Macro.t() | [Macro.t()]) :: MapSet.t(call())
  def collect(forms) when is_list(forms) do
    Enum.reduce(forms, MapSet.new(), &MapSet.union(scan_form(&1), &2))
  end

  def collect(form), do: scan_form(form)

  @doc "Returns target signatures seen only from compile-time call sites."
  @spec compile_time_only(MapSet.t(call())) :: %{optional(String.t()) => MapSet.t(signature())}
  def compile_time_only(calls) do
    phases =
      Enum.reduce(calls, %{}, fn {target, signature, phase}, acc ->
        Map.update(acc, {target, signature}, MapSet.new([phase]), &MapSet.put(&1, phase))
      end)

    Enum.reduce(phases, %{}, fn
      {{target, signature}, phases}, acc ->
        if phases == MapSet.new([:compile_time]) do
          Map.update(acc, target, MapSet.new([signature]), &MapSet.put(&1, signature))
        else
          acc
        end
    end)
  end

  defp scan_form({kind, _, [_head, [do: body]]}) when kind in @definition_kinds,
    do: walk(body, :runtime)

  defp scan_form({kind, _, [_head, [do: body]]}) when kind in @macro_kinds,
    do: walk(body, :compile_time)

  defp scan_form({kind, _, arguments} = form) when kind in @container_kinds do
    case take_body(arguments) do
      {:ok, body, remaining} ->
        remaining
        |> walk(:compile_time)
        |> MapSet.union(collect(body_forms(body)))

      :error ->
        walk(form, :compile_time)
    end
  end

  defp scan_form(form), do: walk(form, :compile_time)

  defp walk({:quote, _, arguments}, phase) when is_list(arguments) do
    case take_body(arguments) do
      {:ok, body, remaining} ->
        remaining
        |> walk(phase)
        |> MapSet.union(walk(body, :runtime))

      :error ->
        walk(arguments, phase)
    end
  end

  defp walk({kind, _, [expression]}, :runtime) when kind in [:unquote, :unquote_splicing],
    do: walk(expression, :compile_time)

  defp walk({{:., _, [target_ast, function]}, _, arguments}, phase)
       when is_atom(function) and is_list(arguments) do
    nested = walk([target_ast | arguments], phase)

    case module_name(target_ast) do
      nil -> nested
      target -> MapSet.put(nested, {target, {function, length(arguments)}, phase})
    end
  end

  defp walk(tuple, phase) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> walk(phase)

  defp walk(list, phase) when is_list(list) do
    Enum.reduce(list, MapSet.new(), fn item, calls ->
      MapSet.union(calls, walk(item, phase))
    end)
  end

  defp walk(_other, _phase), do: MapSet.new()

  defp take_body(arguments) do
    {bodies, remaining} =
      Enum.map_reduce(arguments, [], fn
        options, remaining when is_list(options) ->
          if Keyword.keyword?(options) and Keyword.has_key?(options, :do) do
            {{:body, Keyword.fetch!(options, :do)}, [Keyword.delete(options, :do) | remaining]}
          else
            {nil, [options | remaining]}
          end

        argument, remaining ->
          {nil, [argument | remaining]}
      end)

    case Enum.reject(bodies, &is_nil/1) do
      [{:body, body}] -> {:ok, body, Enum.reverse(remaining)}
      _ -> :error
    end
  end

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp module_name({:__aliases__, _, parts}) when is_list(parts) do
    parts |> Module.concat() |> inspect()
  end

  defp module_name(module) when is_atom(module) do
    if String.starts_with?(Atom.to_string(module), "Elixir."), do: inspect(module)
  end

  defp module_name(_target), do: nil
end
