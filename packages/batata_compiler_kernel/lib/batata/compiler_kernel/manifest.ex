defmodule Batata.CompilerKernel.Manifest do
  @moduledoc """
  Builds Batata instances of Beaver's provider-neutral compiler-kernel manifest.

  The finished artifact digest is written only to the sidecar. The remaining
  manifest identity can therefore be embedded in the shared library without a
  self-referential hash. All revision and ABI inputs are explicit build inputs;
  this module never derives provenance from the current working directory.
  """

  alias Batata.CompilerKernel
  alias Beaver.MLIR.CompilationRuntime
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest

  @entrypoints %{
    "abi_version" => "batata_conversion_abi_version",
    "manifest" => "batata_conversion_manifest",
    "populate" => "batata_populate_ex_patterns"
  }
  @patterns [
    %{"name" => "batata.ex.add", "root" => "ex.add", "version" => "1"},
    %{"name" => "batata.ex.cmp", "root" => "ex.cmp", "version" => "1"},
    %{"name" => "batata.ex.div", "root" => "ex.div", "version" => "1"},
    %{"name" => "batata.ex.lit", "root" => "ex.lit", "version" => "1"},
    %{"name" => "batata.ex.mul", "root" => "ex.mul", "version" => "1"},
    %{"name" => "batata.ex.rem", "root" => "ex.rem", "version" => "1"},
    %{"name" => "batata.ex.sub", "root" => "ex.sub", "version" => "1"},
    %{"name" => "batata.ex.to_word", "root" => "ex.to_word", "version" => "1"},
    %{"name" => "batata.ex.unbox", "root" => "ex.unbox", "version" => "1"},
    %{"name" => "batata.ex.yield", "root" => "ex.yield", "version" => "1"}
  ]
  @capabilities ["ir.attribute.v1", "ir.scalar.v1", "pattern.register"]
  @allowed_options [
    :beaver_revision,
    :bootstrap_provenance,
    :bootstrap_seed,
    :bootstrap_stage,
    :capabilities,
    :compiler_revision,
    :dialect_schema_digest,
    :entrypoints,
    :patterns,
    :runtime_abi_digest,
    :target
  ]

  @doc "Builds and validates a manifest for a finished native artifact."
  @spec build!(Path.t(), keyword()) :: KernelManifest.t()
  def build!(artifact_path, opts) when is_binary(artifact_path) and is_list(opts) do
    require_absolute_artifact!(artifact_path)
    reject_unknown_options!(opts)

    KernelManifest.new!(%{
      "schema_version" => KernelManifest.schema_version(),
      "compiler_kernel_abi_version" => KernelManifest.abi_version(),
      "provider" => CompilerKernel.provider(),
      "compiler_revision" => Keyword.fetch!(opts, :compiler_revision),
      "beaver_revision" => Keyword.fetch!(opts, :beaver_revision),
      "llvm_revision" => CompilationRuntime.llvm_revision(),
      "dialect_schema_digest" => Keyword.fetch!(opts, :dialect_schema_digest),
      "runtime_abi_digest" => Keyword.get(opts, :runtime_abi_digest, "none"),
      "patterns" => Keyword.get(opts, :patterns, @patterns),
      "capabilities" => Keyword.get(opts, :capabilities, @capabilities),
      "target" => Keyword.fetch!(opts, :target),
      "artifact_sha256" => digest_file!(artifact_path),
      "entrypoints" => Keyword.get(opts, :entrypoints, @entrypoints),
      "bootstrap" => %{
        "stage" => Keyword.get(opts, :bootstrap_stage, "stage1"),
        "seed" => Keyword.get(opts, :bootstrap_seed, "cpp-bootstrap"),
        "provenance" => Keyword.fetch!(opts, :bootstrap_provenance)
      }
    })
  end

  @doc "Writes canonical manifest JSON beside the artifact and returns its path."
  @spec write_sidecar!(KernelManifest.t(), Path.t()) :: Path.t()
  def write_sidecar!(%KernelManifest{} = manifest, output_dir) when is_binary(output_dir) do
    File.mkdir_p!(output_dir)
    path = Path.join(output_dir, CompilerKernel.sidecar_name())
    File.write!(path, KernelManifest.encode!(manifest))
    path
  end

  defp require_absolute_artifact!(path) do
    unless Path.type(path) == :absolute and File.regular?(path) do
      raise ArgumentError, "compiler-kernel artifact must be an existing absolute file: #{path}"
    end
  end

  defp reject_unknown_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "compiler-kernel manifest options must be a keyword list"
    end

    case Keyword.keys(opts) -- @allowed_options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "unknown compiler-kernel manifest options: #{inspect(unknown)}"
    end
  end

  defp digest_file!(path) do
    "sha256:" <>
      (path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
  end
end
