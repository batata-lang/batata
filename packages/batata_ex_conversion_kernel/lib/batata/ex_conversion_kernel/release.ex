defmodule Batata.ExConversionKernel.Release do
  @moduledoc """
  Builds an auditable Stage 1/2 Ex conversion kernel release directory.

  All identity inputs are explicit except the Ex schema, term runtime ABI,
  LLVM revision, and frozen Stage 0 digest, which are read from the exact
  dependencies executing the build. The release index contains only relative
  paths so the same artifact layout can be uploaded from any runner.
  """

  alias Batata.ExConversionKernel
  alias Batata.ExConversionKernel.Bootstrap
  alias Batata.ExConversionKernel.Performance
  alias Batata.Memory
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Ex.Stage0
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest
  alias Beaver.MLIR.Dialect.Ex, as: ExDialect

  @required_options [:beaver_revision, :compiler_revision, :target]

  @type output() :: %{
          index: map(),
          index_path: Path.t(),
          performance_receipt: Path.t(),
          stage1: Bootstrap.output(),
          stage2: Bootstrap.output()
        }

  @doc "Builds Stage 1 and Stage 2, verifies both, and writes the release index."
  @spec build!(Path.t(), MLIR.Context.t(), keyword()) :: output()
  def build!(output_dir, ctx, opts)
      when is_binary(output_dir) and is_list(opts) do
    opts = validate_options!(opts)
    output_dir = Path.expand(output_dir)
    build_opts = build_options(opts)

    stage1 = Bootstrap.build!(Path.join(output_dir, "stage1"), ctx, build_opts)
    stage2 = Bootstrap.rebuild!(Path.join(output_dir, "stage2"), ctx, stage1, build_opts)

    verify_output!(stage1, "stage1", "cpp-bootstrap")
    verify_output!(stage2, "stage2", "previous-native")

    performance_receipt = Path.join(output_dir, "performance-receipt.json")

    performance =
      Performance.profile!(stage2, ctx, performance_receipt,
        sizes: Keyword.get(opts, :profile_sizes, [32, 256, 2048]),
        beaver_revision: Keyword.fetch!(opts, :beaver_revision),
        dialect_schema_digest: ExDialect.schema_digest(),
        runtime_abi_digest: Batata.TermRuntime.abi_digest(),
        target: Keyword.fetch!(opts, :target)
      )

    index = release_index(stage1, stage2, performance, opts)
    index_path = Path.join(output_dir, "release-index.json")
    File.write!(index_path, Memory.canonical_json(index) <> "\n")

    %{
      index: index,
      index_path: index_path,
      performance_receipt: performance_receipt,
      stage1: stage1,
      stage2: stage2
    }
  end

  defp validate_options!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "release options must be a keyword list")

    allowed = @required_options ++ [:beaver_path, :profile_sizes]
    missing = @required_options -- Keyword.keys(opts)
    unknown = Keyword.keys(opts) -- allowed

    cond do
      missing != [] ->
        raise ArgumentError,
              "missing Ex conversion kernel release options: #{inspect(missing)}"

      unknown != [] ->
        raise ArgumentError,
              "unknown Ex conversion kernel release options: #{inspect(unknown)}"

      true ->
        opts
    end
  end

  defp build_options(opts) do
    beaver_revision = Keyword.fetch!(opts, :beaver_revision)

    [
      compiler_revision: Keyword.fetch!(opts, :compiler_revision),
      beaver_revision: beaver_revision,
      dialect_schema_digest: ExDialect.schema_digest(),
      runtime_abi_digest: Batata.TermRuntime.abi_digest(),
      target: Keyword.fetch!(opts, :target),
      bootstrap_provenance: "beaver-stage0:" <> Stage0.identity_digest(),
      dependency_pins: %{
        "beaver" => beaver_revision,
        "llvm" => MLIR.CompilationRuntime.llvm_revision()
      }
    ]
    |> maybe_put_beaver_path(opts)
  end

  defp maybe_put_beaver_path(build_opts, opts) do
    case Keyword.fetch(opts, :beaver_path) do
      {:ok, path} -> Keyword.put(build_opts, :beaver_path, path)
      :error -> build_opts
    end
  end

  defp verify_output!(output, stage, seed) do
    manifest = output.kernel_manifest
    ^manifest = KernelManifest.verify_artifact!(manifest, output.library)

    unless manifest.bootstrap == %{
             "stage" => stage,
             "seed" => seed,
             "provenance" => manifest.bootstrap["provenance"]
           } do
      raise "unexpected #{stage} bootstrap manifest"
    end
  end

  defp release_index(stage1, stage2, performance, opts) do
    %{
      "schema_version" => 1,
      "artifact_kind" => "batata-ex-conversion-kernel-release",
      "compiler_revision" => Keyword.fetch!(opts, :compiler_revision),
      "beaver_revision" => Keyword.fetch!(opts, :beaver_revision),
      "llvm_revision" => MLIR.CompilationRuntime.llvm_revision(),
      "dialect_schema_digest" => ExDialect.schema_digest(),
      "runtime_abi_digest" => Batata.TermRuntime.abi_digest(),
      "target" => Keyword.fetch!(opts, :target),
      "stage0" => ExConversionKernel.seed_manifest!(),
      "stages" => [stage_entry(stage1, "stage1"), stage_entry(stage2, "stage2")],
      "performance_receipt" => %{
        "path" => "performance-receipt.json",
        "sha256" => digest(Memory.canonical_json(performance) <> "\n"),
        "callback_free" => performance["callback_free"],
        "sizes" => performance["sizes"]
      },
      "production_ex_conversion_kernel_identity" =>
        KernelManifest.identity_digest(stage2.kernel_manifest)
    }
  end

  defp stage_entry(output, stage) do
    %{
      "stage" => stage,
      "directory" => stage,
      "library" => Path.basename(output.library),
      "manifest" => Path.basename(output.kernel_manifest_path),
      "bootstrap_receipt" => Path.basename(output.bootstrap_receipt),
      "artifact_sha256" => output.kernel_manifest.artifact_sha256,
      "kernel_identity" => KernelManifest.identity_digest(output.kernel_manifest),
      "bootstrap" => output.kernel_manifest.bootstrap,
      "lowered_ir_sha256" => output.lowered_ir_digest
    }
  end

  defp digest(bytes) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end
end
