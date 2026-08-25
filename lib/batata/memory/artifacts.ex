defmodule Batata.Memory.Artifacts do
  @moduledoc "Deterministic M0 memory-plan and diagnostic artifacts."

  alias Batata.Memory
  alias Batata.Memory.{DiagnosticError, Plan, Verifier}

  @plan_filename "memory-plan.json"
  @diagnostics_filename "memory-diagnostics.json"

  @doc "Path of the canonical memory plan inside an output directory."
  @spec plan_path(Path.t()) :: Path.t()
  def plan_path(output_dir), do: Path.join(output_dir, @plan_filename)

  @doc "Path of the canonical memory diagnostics inside an output directory."
  @spec diagnostics_path(Path.t()) :: Path.t()
  def diagnostics_path(output_dir), do: Path.join(output_dir, @diagnostics_filename)

  @doc "Writes M0 artifacts atomically and returns their paths."
  @spec write!(Path.t(), Plan.t()) :: %{memory_plan: Path.t(), memory_diagnostics: Path.t()}
  def write!(output_dir, %Plan{} = plan) do
    File.mkdir_p!(output_dir)

    plan_path = plan_path(output_dir)
    diagnostics_path = diagnostics_path(output_dir)

    diagnostics =
      plan.obligations
      |> Enum.sort_by(&{&1.site.id, to_string(&1.kind)})
      |> Enum.map(fn obligation ->
        obligation
        |> Verifier.diagnostic(plan.policy)
        |> DiagnosticError.to_map()
      end)

    write_atomic!(plan_path, Plan.canonical_json(plan) <> "\n")

    write_atomic!(
      diagnostics_path,
      Memory.canonical_json(%{
        "diagnostics" => diagnostics,
        "plan_hash" => Plan.digest(plan),
        "schema" => "batata-memory-diagnostics/1"
      }) <> "\n"
    )

    %{memory_plan: plan_path, memory_diagnostics: diagnostics_path}
  end

  defp write_atomic!(path, contents) do
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    try do
      File.write!(temporary, contents, [:binary])
      File.rename!(temporary, path)
    after
      File.rm(temporary)
    end

    path
  end
end
