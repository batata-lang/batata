defmodule Batata.Probe.CorpusRuntimeSlice do
  @moduledoc """
  Removes source-proven compile-time-only definitions from a normalized corpus.

  The slice is conservative: a public signature requires compile-time incoming
  evidence and no runtime incoming edge before it can stop being a runtime root.
  Macro-exclusive local helpers are removed transitively by the same dependency
  analysis used for diagnostic source slices.
  """

  alias Batata.Frontend
  alias Batata.Probe.{CallPhase, DiagnosticSlice, Inventory}

  @type result :: %{
          required(:modules) => [Frontend.Module.t()],
          required(:removed_definitions) => [map()]
        }

  @spec slice(Path.t(), [Frontend.Module.t()]) :: result()
  def slice(source, modules) when is_list(modules) do
    files = Inventory.discover!(source)
    compile_time_public = compile_time_public(files)
    removed_by_module = removed_by_module(files, compile_time_public)

    sliced_modules =
      Enum.map(modules, fn module ->
        removed = Map.get(removed_by_module, inspect(module.name), MapSet.new())

        definitions =
          Enum.reject(module.definitions, fn definition ->
            MapSet.member?(removed, {definition.name, definition.arity})
          end)

        %{module | definitions: definitions}
      end)

    %{
      modules: sliced_modules,
      removed_definitions: removed_evidence(removed_by_module)
    }
  end

  defp compile_time_public(files) do
    files
    |> Enum.reduce(MapSet.new(), fn file, calls ->
      module_calls =
        file.modules
        |> Enum.flat_map(& &1.dependency_forms)
        |> CallPhase.collect()

      top_level_calls =
        file.top_level_unsupported
        |> Enum.map(& &1.form_ast)
        |> CallPhase.collect()

      calls
      |> MapSet.union(module_calls)
      |> MapSet.union(top_level_calls)
    end)
    |> CallPhase.compile_time_only()
  end

  defp removed_by_module(files, compile_time_public) do
    files
    |> Enum.flat_map(& &1.modules)
    |> Enum.reduce(%{}, fn module, removed ->
      external = Map.get(compile_time_public, module.module, MapSet.new())

      signatures =
        DiagnosticSlice.compile_time_only_signatures(module.dependency_forms, external)

      Map.update(removed, module.module, signatures, &MapSet.union(&1, signatures))
    end)
  end

  defp removed_evidence(removed_by_module) do
    removed_by_module
    |> Enum.flat_map(fn {module, signatures} ->
      Enum.map(signatures, fn {function, arity} ->
        %{
          "module" => module,
          "function" => Atom.to_string(function),
          "arity" => arity
        }
      end)
    end)
    |> Enum.sort_by(&{&1["module"], &1["function"], &1["arity"]})
  end
end
