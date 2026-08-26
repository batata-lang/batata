defmodule Batata.Probe.ClosureFrontier do
  @moduledoc """
  Classifies dynamic-function application sites without changing compilation.

  The classifier operates on the same expanded definition forms retained by
  the corpus inventory. It records where a callable comes from, but makes no
  claim that external closures can cross a module or host boundary.
  """

  @provenances ~w(module_local caller_parameter cross_module_capture other_external)

  @doc "Collects deterministic closure-frontier entries from inventory files."
  @spec collect([map()]) :: [map()]
  def collect(files) do
    files
    |> Enum.flat_map(fn file ->
      file.modules
      |> Enum.map(&module_entry(file.path, &1))
      |> Enum.reject(&(&1["sites"] == []))
    end)
    |> Enum.sort_by(&{&1["path"], &1["module"]})
  end

  @doc "Returns the stable set of provenance labels emitted by the report."
  @spec provenances() :: [String.t()]
  def provenances, do: @provenances

  defp module_entry(path, module) do
    {local_fn_count, sites} =
      Enum.reduce(module.dependency_forms, {0, []}, fn form, {fn_count, sites} ->
        case definition(form) do
          {:ok, function, arity, parameters, body} ->
            {
              fn_count + count_anonymous_functions(body),
              sites ++ dynamic_apply_sites(body, function, arity, parameters)
            }

          :error ->
            {fn_count, sites}
        end
      end)

    %{
      "path" => path,
      "module" => module.module,
      "local_fn_count" => local_fn_count,
      "sites" => Enum.sort_by(sites, &{&1["line"], &1["function"], &1["arity"]})
    }
  end

  defp definition({kind, _, [head, [do: body]]}) when kind in [:def, :defp] do
    with {:ok, function, args} <- definition_head(head) do
      {:ok, to_string(function), length(args), parameter_names(args), body}
    end
  end

  defp definition(_form), do: :error

  defp definition_head({:when, _, [head | _guards]}), do: definition_head(head)

  defp definition_head({function, _, args})
       when is_atom(function) and is_list(args),
       do: {:ok, function, args}

  defp definition_head(_head), do: :error

  defp parameter_names(args) do
    Enum.reduce(args, MapSet.new(), fn arg, names ->
      {_arg, names} =
        Macro.prewalk(arg, names, &collect_parameter/2)

      names
    end)
  end

  defp collect_parameter({name, _, context} = node, names)
       when is_atom(name) and (is_atom(context) or is_nil(context)) do
    if name == :_, do: {node, names}, else: {node, MapSet.put(names, name)}
  end

  defp collect_parameter(node, names), do: {node, names}

  defp dynamic_apply_sites(body, function, arity, parameters) do
    {_body, sites} =
      Macro.prewalk(body, [], fn
        {{:., dot_meta, [callee]}, call_meta, args} = node, sites when is_list(args) ->
          site = %{
            "function" => function,
            "arity" => arity,
            "line" => call_meta[:line] || dot_meta[:line],
            "provenance" => provenance(callee, parameters)
          }

          {node, [site | sites]}

        node, sites ->
          {node, sites}
      end)

    Enum.reverse(sites)
  end

  defp provenance({:__fn_ref__, _, _}, _parameters), do: "module_local"
  defp provenance({:fn, _, _}, _parameters), do: "module_local"

  defp provenance({:&, _, [{:/, _, [capture, capture_arity]}]}, _parameters)
       when is_integer(capture_arity) do
    if remote_capture?(capture), do: "cross_module_capture", else: "module_local"
  end

  defp provenance({name, _, context}, parameters)
       when is_atom(name) and (is_atom(context) or is_nil(context)) do
    if MapSet.member?(parameters, name), do: "caller_parameter", else: "other_external"
  end

  defp provenance(_callee, _parameters), do: "other_external"

  defp remote_capture?({{:., _, [module, function]}, _, []}) when is_atom(function),
    do: match?({:__aliases__, _, _}, module) or is_atom(module)

  defp remote_capture?(_capture), do: false

  defp count_anonymous_functions(body) do
    {_body, count} =
      Macro.prewalk(body, 0, fn
        {:fn, _, _} = node, count -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end
end
