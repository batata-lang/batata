defmodule Batata.Probe.Jason.DiagnosticAttempt do
  @moduledoc """
  Runs explicitly non-coverage diagnostic attempts after removing a narrow,
  identified set of module blockers.

  These results never contribute to compile eligibility or pass counts. A
  macro-only module is recorded as synthetic-only instead of compiling a
  generated `main/0` that contains none of the corpus semantics.
  """

  alias Batata.Probe.Jason.{BlockerIdentity, CompileAttempt}

  @doc "Runs deterministic shadow diagnostics for eligible blocked modules."
  @spec run([map()]) :: [map()]
  def run(files) do
    files
    |> Enum.flat_map(fn file ->
      Enum.flat_map(file.modules, &attempt(file.path, &1))
    end)
    |> Enum.sort_by(&{&1["path"], &1["module"]})
  end

  defp attempt(path, %{diagnostic_source: source} = module) when is_binary(source) do
    result = CompileAttempt.run_source(path, module.module, source)

    details =
      result
      |> Map.drop(["path", "module", "status"])
      |> Map.put("phase", diagnostic_phase(result["status"]))

    [
      Map.merge(details, %{
        "path" => path,
        "module" => module.module,
        "diagnostic_only" => true,
        "outcome" => "reached_compile_pipeline",
        "removed_blockers" => removed_blockers(path, module)
      })
    ]
  end

  defp attempt(path, module) do
    blockers = semantic_blockers(module)

    if blockers != [] and Enum.all?(blockers, &(&1.reason == :macro_definition)) do
      [
        %{
          "path" => path,
          "module" => module.module,
          "diagnostic_only" => true,
          "outcome" => "synthetic_only",
          "phase" => "not_attempted",
          "removed_blockers" => removed_blockers(path, module)
        }
      ]
    else
      []
    end
  end

  defp diagnostic_phase("pass"), do: "lowering_complete"
  defp diagnostic_phase(status), do: status

  defp removed_blockers(path, module) do
    module
    |> semantic_blockers()
    |> Enum.map(fn blocker ->
      %{
        "id" => BlockerIdentity.id(path, module.module, blocker),
        "reason" => to_string(blocker.reason)
      }
    end)
  end

  defp semantic_blockers(module) do
    Enum.reject(module.unsupported, &(&1.reason == :ignored_metadata))
  end
end
