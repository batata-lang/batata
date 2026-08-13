defmodule Batata.Probe.Jason.DependencyFrontier do
  @moduledoc """
  Measures remote calls at the boundary of module-scoped compile attempts.

  The result is diagnostic only: it does not resolve, load, or compile target
  modules. Calls to modules present in the same corpus are distinguished from
  external calls so future multi-module work can be prioritized by evidence.
  """

  @doc "Collects deterministic remote-call counts from every discovered module."
  @spec collect([map()]) :: [map()]
  def collect(files) do
    corpus_modules =
      files
      |> Enum.flat_map(& &1.modules)
      |> MapSet.new(& &1.module)

    files
    |> Enum.flat_map(&file_calls(&1, corpus_modules))
    |> Enum.frequencies()
    |> Enum.map(fn
      {{path, source, target, function, arity, target_kind, source_eligibility,
        blocker_categories}, count} ->
        %{
          "path" => path,
          "module" => source,
          "target" => target,
          "function" => Atom.to_string(function),
          "arity" => arity,
          "target_kind" => target_kind,
          "source_eligibility" => source_eligibility,
          "blocker_categories" => Map.new(blocker_categories),
          "count" => count
        }
    end)
    |> Enum.sort_by(&{&1["path"], &1["module"], &1["target"], &1["function"], &1["arity"]})
  end

  defp file_calls(file, corpus_modules) do
    Enum.flat_map(file.modules, &module_calls(&1, file.path, corpus_modules))
  end

  defp module_calls(module, path, corpus_modules) do
    source_eligibility =
      if module.compile_source, do: "compile_eligible", else: "blocked_by_module_forms"

    blocker_categories =
      module.unsupported
      |> Enum.reject(&(&1.reason == :ignored_metadata))
      |> Enum.frequencies_by(&to_string(&1.reason))
      |> Enum.sort()

    module.dependency_forms
    |> then(&{:__block__, [], &1})
    |> remote_calls()
    |> Enum.map(fn {target, function, arity} ->
      target_kind = if MapSet.member?(corpus_modules, target), do: "corpus", else: "external"

      {path, module.module, target, function, arity, target_kind, source_eligibility,
       blocker_categories}
    end)
  end

  defp remote_calls(ast) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {{:., _, [target_ast, function]}, _, args} = node, calls
        when is_atom(function) and is_list(args) ->
          case module_name(target_ast) do
            nil -> {node, calls}
            target -> {node, [{target, function, length(args)} | calls]}
          end

        node, calls ->
          {node, calls}
      end)

    calls
  end

  defp module_name({:__aliases__, _, parts}) when is_list(parts) do
    parts |> Module.concat() |> inspect()
  end

  defp module_name(module) when is_atom(module) do
    if String.starts_with?(Atom.to_string(module), "Elixir."), do: inspect(module)
  end

  defp module_name(_target), do: nil
end
