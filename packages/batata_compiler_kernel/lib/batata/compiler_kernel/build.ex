defmodule Batata.CompilerKernel.Build do
  @moduledoc """
  Builds the Batata-authored Ex conversion source into a native kernel.

  Stage 0 compiles the Batata conversion source to one PIC object. A small C ABI
  adapter transports opaque MLIR handles and calls those Batata AOT symbols on
  the same conversion worker; it contains no BEAM or NIF calls. The final
  dynamic export allowlist contains only the three versioned kernel entrypoints.
  """

  alias Batata.{AOT, Export, Library}
  alias Batata.CompilerKernel
  alias Batata.CompilerKernel.Manifest
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest

  @semantic_exports [
    %{function: :pattern_accept, arity: 4, symbol: "batata_kernel_pattern_accept"},
    %{function: :target_length, arity: 1, symbol: "batata_kernel_target_length"},
    %{function: :target_word, arity: 2, symbol: "batata_kernel_target_word"},
    %{function: :cmp_predicate, arity: 2, symbol: "batata_kernel_cmp_predicate"},
    %{function: :runtime_arity, arity: 1, symbol: "batata_kernel_runtime_arity"},
    %{function: :structural_limit, arity: 1, symbol: "batata_kernel_structural_limit"}
  ]
  @allowed_options [
    :beaver_path,
    :beaver_revision,
    :bootstrap_provenance,
    :compiler_revision,
    :dependency_pins,
    :dialect_schema_digest,
    :runtime_abi_digest,
    :target
  ]

  @type output() :: %{
          library: Path.t(),
          object: Path.t(),
          kernel_manifest: KernelManifest.t(),
          kernel_manifest_path: Path.t(),
          bundle: Path.t(),
          artifact_index: Path.t(),
          build_manifest: Path.t()
        }

  @doc "Builds the Stage 1 compiler-kernel artifact and receipts."
  @spec build!(Path.t(), Beaver.MLIR.Context.t(), keyword()) :: output()
  def build!(output_dir, ctx, opts)
      when is_binary(output_dir) and is_list(opts) do
    reject_unknown_options!(opts)
    File.mkdir_p!(output_dir)
    source = File.read!(CompilerKernel.conversion_source_path())
    object_path = Path.join(output_dir, "batata-ex-conversion.o")
    library_path = Path.join(output_dir, AOT.library_name("batata_ex_conversion"))

    %{exports: semantic_exports, snapshot: snapshot} =
      Library.compile_object!(source, object_path, ctx, @semantic_exports)

    File.write!(library_path, "")
    draft = Manifest.build!(library_path, manifest_options(opts))
    identity = KernelManifest.identity_digest(draft)
    entrypoints = draft.entrypoints |> Map.values() |> Enum.sort()

    AOT.link_shared_library!(object_path, library_path, semantic_exports,
      extra_sources: [CompilerKernel.native_adapter_path()],
      compiler_args: native_compiler_args(identity, opts),
      public_symbols: entrypoints
    )

    kernel_manifest = Manifest.build!(library_path, manifest_options(opts))

    unless KernelManifest.identity_digest(kernel_manifest) == identity do
      raise "compiler-kernel identity changed after artifact hashing"
    end

    kernel_manifest_path = Manifest.write_sidecar!(kernel_manifest, output_dir)
    abi_exports = Enum.map(entrypoints, &%{"function" => "compiler-kernel ABI", "symbol" => &1})
    :ok = Export.verify_exact_symbols!(library_path, abi_exports)

    metadata =
      Export.write!(output_dir, snapshot.name,
        source: source,
        artifact_paths: [kernel_manifest_path, library_path, object_path],
        definitions: snapshot.definitions,
        exports: abi_exports,
        entry: nil,
        bundle_metadata: %{
          "artifact_kind" => "compiler-kernel",
          "compiler_abi" => %{
            "name" => "beaver-compiler-kernel",
            "version" => KernelManifest.abi_version()
          },
          "dependency_pins" => Keyword.fetch!(opts, :dependency_pins),
          "kernel_identity" => identity,
          "bootstrap" => kernel_manifest.bootstrap
        }
      )

    %{
      library: library_path,
      object: object_path,
      kernel_manifest: kernel_manifest,
      kernel_manifest_path: kernel_manifest_path,
      bundle: metadata.bundle,
      artifact_index: metadata.artifact_index,
      build_manifest: metadata.manifest
    }
  end

  defp manifest_options(opts) do
    [
      compiler_revision: Keyword.fetch!(opts, :compiler_revision),
      beaver_revision: Keyword.fetch!(opts, :beaver_revision),
      dialect_schema_digest: Keyword.fetch!(opts, :dialect_schema_digest),
      runtime_abi_digest: Keyword.fetch!(opts, :runtime_abi_digest),
      target: Keyword.fetch!(opts, :target),
      bootstrap_provenance: Keyword.fetch!(opts, :bootstrap_provenance)
    ]
  end

  defp native_compiler_args(identity, opts) do
    beaver_path = Keyword.get(opts, :beaver_path) || System.fetch_env!("BEAVER_PATH")
    llvm_config = System.fetch_env!("LLVM_CONFIG_PATH")

    llvm_include =
      case System.cmd(llvm_config, ["--includedir"], stderr_to_stdout: true) do
        {path, 0} -> String.trim(path)
        {output, status} -> raise "llvm-config --includedir failed (#{status}): #{output}"
      end

    [
      "-I#{Path.join(beaver_path, "native/include")}",
      "-I#{llvm_include}",
      "-DBATATA_KERNEL_IDENTITY=#{inspect(identity)}"
    ]
  end

  defp reject_unknown_options!(opts) do
    unless Keyword.keyword?(opts) do
      raise ArgumentError, "compiler-kernel build options must be a keyword list"
    end

    case Keyword.keys(opts) -- @allowed_options do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown compiler-kernel build options: #{inspect(unknown)}"
    end
  end
end
