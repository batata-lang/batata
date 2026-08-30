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
  @pattern_roots ~w(
    ex.add
    ex.binary
    ex.binary_part
    ex.call
    ex.cmp
    ex.div
    ex.exported_clone
    ex.exported_destroy
    ex.exported_get
    ex.exported_length
    ex.func
    ex.if
    ex.lit
    ex.mul
    ex.process_table_reset
    ex.rem
    ex.result_atom_name
    ex.result_create
    ex.result_destroy
    ex.result_exception_kind
    ex.result_exception_reason
    ex.result_root_kind
    ex.result_root_word
    ex.result_term_get
    ex.result_term_kind
    ex.result_term_length
    ex.return
    ex.runtime_create
    ex.runtime_destroy
    ex.runtime_enter
    ex.runtime_leave
    ex.sub
    ex.term_eq
    ex.term_export
    ex.term_handle_destroy
    ex.term_handle_export
    ex.term_import
    ex.to_word
    ex.unbox
    ex.yield
  )
  @patterns @pattern_roots
            |> Enum.sort()
            |> Enum.map(fn root ->
              %{"name" => "batata." <> root, "root" => root, "version" => "1"}
            end)
  @capabilities [
    "ir.attribute.v1",
    "ir.region.v1",
    "ir.scalar.v1",
    "ir.symbol.v1",
    "pattern.register"
  ]
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
      "runtime_abi_digest" => Keyword.fetch!(opts, :runtime_abi_digest),
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
