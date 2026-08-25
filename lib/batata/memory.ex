defmodule Batata.Memory do
  @moduledoc """
  Versioned data model for proof-carrying memory analysis.

  This namespace deliberately separates Batata's allocation, region, escape,
  and lifetime facts from MLIR's physical read/write/allocate/free effects.
  """

  alias Batata.Memory.CanonicalJSON

  @policies [:disabled, :report, :strict]

  @doc "Encodes a JSON-ready value with sorted object keys and no insignificant whitespace."
  @spec canonical_json(term()) :: String.t()
  defdelegate canonical_json(value), to: CanonicalJSON, as: :encode!

  @doc "Returns a lowercase SHA-256 digest of a canonical JSON-ready value."
  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Analyzes verified `ex` IR and returns its deterministic memory plan."
  @spec analyze(Beaver.MLIR.Module.t(), keyword()) :: Batata.Memory.Plan.t()
  defdelegate analyze(module, opts), to: Batata.Memory.Analyzer

  @doc "Runs the selected memory policy before lowering and returns its plan when enabled."
  @spec verify!(Beaver.MLIR.Module.t(), keyword()) :: :disabled | Batata.Memory.Plan.t()
  defdelegate verify!(module, opts), to: Batata.Memory.Verifier

  @doc "Writes deterministic plan, diagnostic, and optional receipt artifacts."
  @spec write_artifacts!(Path.t(), Batata.Memory.Plan.t()) :: map()
  defdelegate write_artifacts!(output_dir, plan), to: Batata.Memory.Artifacts, as: :write!

  @doc false
  @spec validate_policy!(term()) :: :disabled | :report | :strict
  def validate_policy!(policy) when policy in @policies, do: policy

  def validate_policy!(policy) do
    raise ArgumentError,
          "memory_policy must be :disabled, :report, or :strict, got: #{inspect(policy)}"
  end
end
