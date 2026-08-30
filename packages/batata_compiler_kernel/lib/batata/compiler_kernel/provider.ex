defmodule Batata.CompilerKernel.Provider do
  @moduledoc """
  Constructs and profiles Batata's fail-closed production conversion provider.

  Every compatibility identity is supplied by the current compiler
  environment. The loaded manifest is never allowed to declare its own
  expected values, and no missing or incompatible artifact falls back to a
  BEAM or C++ conversion implementation.
  """

  alias Batata.Memory
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest
  alias Beaver.MLIR.Conversion.Plan

  @required_options [
    :beaver_revision,
    :dialect_schema_digest,
    :runtime_abi_digest,
    :target
  ]

  @doc "Builds the sole production conversion plan for one verified artifact."
  @spec plan!(KernelManifest.t(), Path.t(), keyword()) :: Plan.t()
  def plan!(%KernelManifest{} = manifest, artifact, opts)
      when is_binary(artifact) and is_list(opts) do
    reject_options!(opts)
    ^manifest = KernelManifest.verify_artifact!(manifest, artifact)

    Plan.new(mode: :full, folding_mode: :after_patterns, build_materializations: true)
    |> Plan.add_legal_dialect("builtin")
    |> Plan.add_legal_dialect("func")
    |> Plan.add_legal_dialect("arith")
    |> Plan.add_legal_dialect("cf")
    |> Plan.add_legal_dialect("scf")
    |> Plan.add_legal_dialect("llvm")
    |> Plan.add_illegal_dialect("ex")
    |> Plan.add_conversion_map(~w(!ex.term !ex.bound !ex.unbound), "i64")
    |> Plan.add_external_pattern_population(manifest, artifact,
      expected: [
        beaver_revision: Keyword.fetch!(opts, :beaver_revision),
        dialect_schema_digest: Keyword.fetch!(opts, :dialect_schema_digest),
        runtime_abi_digest: Keyword.fetch!(opts, :runtime_abi_digest),
        target: Keyword.fetch!(opts, :target),
        capabilities: manifest.capabilities
      ]
    )
  end

  @doc """
  Profiles a production conversion and writes its canonical callback receipt.

  A successful native conversion with any BEAM callback is rejected. The
  receipt binds the measured conversion to the verified artifact and bootstrap
  provenance.
  """
  @spec profile!(
          KernelManifest.t(),
          Path.t(),
          MLIR.Conversion.conversion_ir(),
          Path.t(),
          keyword()
        ) :: {MLIR.Conversion.conversion_ir(), map()}
  def profile!(%KernelManifest{} = manifest, artifact, ir, receipt_path, opts)
      when is_binary(artifact) and is_binary(receipt_path) and is_list(opts) do
    {converted, conversion} =
      manifest
      |> plan!(artifact, opts)
      |> Plan.profile!(ir)

    callback_count = get_in(conversion, ["beam", "callback_count"])

    unless callback_count == 0 and conversion["callbacks"] == [] do
      raise "production compiler kernel crossed the BEAM callback boundary"
    end

    receipt = %{
      "schema_version" => 1,
      "provider" => manifest.provider,
      "kernel_identity" => KernelManifest.identity_digest(manifest),
      "artifact_sha256" => manifest.artifact_sha256,
      "bootstrap" => manifest.bootstrap,
      "callback_free" => true,
      "conversion" => conversion
    }

    File.mkdir_p!(Path.dirname(receipt_path))
    File.write!(receipt_path, Memory.canonical_json(receipt) <> "\n")
    {converted, receipt}
  end

  defp reject_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "compiler-kernel provider options must be a keyword list"
    end

    keys = Keyword.keys(opts)
    missing = @required_options -- keys
    unknown = keys -- @required_options

    cond do
      missing != [] ->
        raise ArgumentError,
              "missing compiler-kernel provider options: #{inspect(missing)}"

      unknown != [] ->
        raise ArgumentError,
              "unknown compiler-kernel provider options: #{inspect(unknown)}"

      true ->
        :ok
    end
  end
end
