defmodule Batata.Memory.Artifacts do
  @moduledoc "Deterministic memory-plan, diagnostic, and closed-proof artifacts."

  alias Batata.Memory
  alias Batata.Memory.{DiagnosticError, Plan, Receipt, Repair, Verifier}

  @plan_filename "memory-plan.json"
  @diagnostics_filename "memory-diagnostics.json"
  @receipt_filename "memory-receipt.json"
  @repair_filename "memory-repair.json"

  @doc "Path of the canonical memory plan inside an output directory."
  @spec plan_path(Path.t()) :: Path.t()
  def plan_path(output_dir), do: Path.join(output_dir, @plan_filename)

  @doc "Path of the canonical memory diagnostics inside an output directory."
  @spec diagnostics_path(Path.t()) :: Path.t()
  def diagnostics_path(output_dir), do: Path.join(output_dir, @diagnostics_filename)

  @doc "Path of a bounded receipt inside an output directory."
  @spec receipt_path(Path.t()) :: Path.t()
  def receipt_path(output_dir), do: Path.join(output_dir, @receipt_filename)

  @doc "Path of a machine-readable repair request inside an output directory."
  @spec repair_path(Path.t()) :: Path.t()
  def repair_path(output_dir), do: Path.join(output_dir, @repair_filename)

  @doc "Writes M0 artifacts atomically and returns their paths."
  @spec write!(Path.t(), Plan.t()) :: map()
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

    maybe_write_proof_or_repair(
      %{memory_plan: plan_path, memory_diagnostics: diagnostics_path},
      output_dir,
      plan
    )
  end

  defp maybe_write_proof_or_repair(paths, output_dir, %Plan{obligations: []} = plan) do
    contracts =
      Map.new(plan.preconditions, fn precondition ->
        {precondition["variable"], String.to_integer(precondition["maximum_bytes"])}
      end)

    receipt = Receipt.from_plan!(plan, contracts)
    path = receipt_path(output_dir)
    write_atomic!(path, Receipt.canonical_json(receipt) <> "\n")
    Map.put(paths, :memory_receipt, path)
  end

  defp maybe_write_proof_or_repair(paths, output_dir, %Plan{} = plan) do
    path = repair_path(output_dir)
    write_atomic!(path, Repair.canonical_json(plan) <> "\n")
    Map.put(paths, :memory_repair, path)
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
