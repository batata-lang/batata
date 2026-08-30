defmodule Batata.CompilerKernel.Build do
  @moduledoc """
  Builds the Batata-authored Ex conversion source into a native kernel.

  Stage 0 compiles the Batata conversion source to one PIC object. A small C ABI
  adapter transports opaque MLIR handles and calls those Batata AOT symbols on
  the same conversion worker; it contains no BEAM or NIF calls. The final
  dynamic export allowlist contains only the three versioned kernel entrypoints.
  """

  alias Batata.{AOT, Export, Library, Memory}
  alias Batata.CompilerKernel
  alias Batata.CompilerKernel.Manifest
  alias Batata.CompilerKernel.Provider
  alias Beaver.MLIR.Conversion.Ex, as: ExConversion
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest

  @semantic_exports [
    %{function: :pattern_accept, arity: 4, symbol: "batata_kernel_pattern_accept"},
    %{function: :target_length, arity: 1, symbol: "batata_kernel_target_length"},
    %{function: :target_word, arity: 2, symbol: "batata_kernel_target_word"},
    %{function: :cmp_predicate, arity: 2, symbol: "batata_kernel_cmp_predicate"},
    %{function: :runtime_arity, arity: 1, symbol: "batata_kernel_runtime_arity"},
    %{function: :structural_limit, arity: 1, symbol: "batata_kernel_structural_limit"},
    %{function: :term_type_accept, arity: 2, symbol: "batata_kernel_term_type_accept"},
    %{function: :aggregate_accept, arity: 2, symbol: "batata_kernel_aggregate_accept"},
    %{
      function: :function_value_accept,
      arity: 5,
      symbol: "batata_kernel_function_value_accept"
    },
    %{function: :try_accept, arity: 5, symbol: "batata_kernel_try_accept"},
    %{function: :pattern_count, arity: 0, symbol: "batata_kernel_pattern_count"},
    %{
      function: :pattern_namespace_length,
      arity: 0,
      symbol: "batata_kernel_pattern_namespace_length"
    },
    %{
      function: :pattern_namespace_word,
      arity: 1,
      symbol: "batata_kernel_pattern_namespace_word"
    },
    %{
      function: :pattern_root_length,
      arity: 1,
      symbol: "batata_kernel_pattern_root_length"
    },
    %{function: :pattern_root_word, arity: 2, symbol: "batata_kernel_pattern_root_word"},
    %{function: :pattern_target, arity: 1, symbol: "batata_kernel_pattern_target"},
    %{function: :pattern_action, arity: 1, symbol: "batata_kernel_pattern_action"},
    %{function: :rewrite, arity: 1, symbol: "batata_kernel_rewrite"}
  ]
  @compiler_abi_calls [
                        {:healthy, [], :flag},
                        {:converted_operand_count, [], :count},
                        {:source_operand_count, [], :count},
                        {:source_result_count, [], :count},
                        {:converted_operand, [:index], :value},
                        {:source_operand, [:index], :value},
                        {:source_result, [:index], :value},
                        {:operation_location, [], :location},
                        {:value_type, [:value], :type},
                        {:convert_type, [:type], :type},
                        {:type_is_i64, [:type], :flag},
                        {:dynamic_type_length, [:type], :count},
                        {:dynamic_type_tail, [:type], :word},
                        {:operation_attribute, [:index], :attribute},
                        {:attribute_string_length, [:attribute], :count},
                        {:attribute_string_word, [:attribute, :index], :word},
                        {:attribute_integer_value, [:attribute], :word},
                        {:integer_type, [:count], :type},
                        {:integer_attribute, [:type, :word], :attribute},
                        {:builder_reset, [:index, :location], :status},
                        {:builder_add_operand, [:value], :status},
                        {:builder_add_result_type, [:type], :status},
                        {:builder_add_attribute, [:index, :attribute], :status},
                        {:builder_add_flat_symbol, [:index, :index], :status},
                        {:builder_add_flat_symbol_from_attribute, [:index, :attribute], :status},
                        {:builder_create, [], :operation},
                        {:builder_create_call, [:index, :type], :operation},
                        {:operation_result, [:operation, :index], :value},
                        {:replace_one, [:value], :status},
                        {:replace_none, [], :status}
                      ]
                      |> Map.new(fn {function, arguments, result} ->
                        {{CompilerABI.Host, function, length(arguments)},
                         %{
                           symbol: "batata_compiler_abi_#{function}",
                           arguments: arguments,
                           result: result
                         }}
                      end)
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
          bootstrap_receipt: Path.t(),
          lowered_ir_digest: String.t(),
          bundle: Path.t(),
          artifact_index: Path.t(),
          build_manifest: Path.t()
        }

  @doc "Builds the Stage 1 compiler-kernel artifact and receipts."
  @spec build!(Path.t(), Beaver.MLIR.Context.t(), keyword()) :: output()
  def build!(output_dir, ctx, opts)
      when is_binary(output_dir) and is_list(opts) do
    reject_unknown_options!(opts)
    verify_bootstrap_provenance!(opts)

    bootstrap = %{
      "stage" => "stage1",
      "seed" => "cpp-bootstrap",
      "provenance" => Keyword.fetch!(opts, :bootstrap_provenance),
      "source_kernel_identity" => nil
    }

    do_build!(output_dir, ctx, opts, nil, bootstrap)
  end

  @doc "Rebuilds the compiler kernel with a verified Stage 1 kernel."
  @spec rebuild!(Path.t(), Beaver.MLIR.Context.t(), output(), keyword()) :: output()
  def rebuild!(output_dir, ctx, stage1, opts)
      when is_binary(output_dir) and is_map(stage1) and is_list(opts) do
    reject_unknown_options!(opts)
    manifest = Map.fetch!(stage1, :kernel_manifest)
    library = Map.fetch!(stage1, :library)
    %KernelManifest{} = manifest
    ^manifest = KernelManifest.verify_artifact!(manifest, library)
    source_identity = KernelManifest.identity_digest(manifest)

    bootstrap = %{
      "stage" => "stage2",
      "seed" => "previous-native",
      "provenance" => "batata-stage1:" <> source_identity,
      "source_kernel_identity" => source_identity
    }

    do_build!(
      output_dir,
      ctx,
      opts,
      Provider.plan!(manifest, library, provider_options(opts)),
      bootstrap
    )
  end

  defp do_build!(output_dir, ctx, opts, conversion_plan, bootstrap) do
    File.mkdir_p!(output_dir)
    source = File.read!(CompilerKernel.conversion_source_path())
    object_path = Path.join(output_dir, "batata-ex-conversion.o")
    library_path = Path.join(output_dir, AOT.library_name("batata_ex_conversion"))

    compile_options = [
      compiler_abi_calls: @compiler_abi_calls,
      conversion_plan: conversion_plan || ExConversion.plan(),
      scalar_module: true
    ]

    %{
      exports: semantic_exports,
      snapshot: snapshot,
      lowered_ir_digest: lowered_ir_digest
    } = Library.compile_object!(source, object_path, ctx, @semantic_exports, compile_options)

    File.write!(library_path, "")
    draft = Manifest.build!(library_path, manifest_options(opts, bootstrap))
    identity = KernelManifest.identity_digest(draft)
    entrypoints = draft.entrypoints |> Map.values() |> Enum.sort()

    AOT.link_shared_library!(object_path, library_path, semantic_exports,
      extra_sources: [CompilerKernel.native_adapter_path()],
      compiler_args: native_compiler_args(identity, opts),
      public_symbols: entrypoints
    )

    kernel_manifest = Manifest.build!(library_path, manifest_options(opts, bootstrap))

    unless KernelManifest.identity_digest(kernel_manifest) == identity do
      raise "compiler-kernel identity changed after artifact hashing"
    end

    kernel_manifest_path = Manifest.write_sidecar!(kernel_manifest, output_dir)

    bootstrap_receipt =
      write_bootstrap_receipt!(
        output_dir,
        bootstrap,
        identity,
        lowered_ir_digest,
        object_path
      )

    abi_exports = Enum.map(entrypoints, &%{"function" => "compiler-kernel ABI", "symbol" => &1})
    :ok = Export.verify_exact_symbols!(library_path, abi_exports)

    metadata =
      Export.write!(output_dir, snapshot.name,
        source: source,
        artifact_paths: [bootstrap_receipt, kernel_manifest_path, library_path, object_path],
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
      bootstrap_receipt: bootstrap_receipt,
      lowered_ir_digest: lowered_ir_digest,
      bundle: metadata.bundle,
      artifact_index: metadata.artifact_index,
      build_manifest: metadata.manifest
    }
  end

  defp manifest_options(opts, bootstrap) do
    [
      compiler_revision: Keyword.fetch!(opts, :compiler_revision),
      beaver_revision: Keyword.fetch!(opts, :beaver_revision),
      dialect_schema_digest: Keyword.fetch!(opts, :dialect_schema_digest),
      runtime_abi_digest: Keyword.fetch!(opts, :runtime_abi_digest),
      target: Keyword.fetch!(opts, :target),
      bootstrap_stage: Map.fetch!(bootstrap, "stage"),
      bootstrap_seed: Map.fetch!(bootstrap, "seed"),
      bootstrap_provenance: Map.fetch!(bootstrap, "provenance")
    ]
  end

  defp verify_bootstrap_provenance!(opts) do
    seed = CompilerKernel.seed_manifest!()
    expected = "beaver-stage0:" <> Map.fetch!(seed, "identity_digest")
    actual = Keyword.fetch!(opts, :bootstrap_provenance)

    unless actual == expected do
      raise ArgumentError,
            "bootstrap provenance must match the frozen Beaver Stage 0 identity: #{expected}"
    end
  end

  defp provider_options(opts) do
    Keyword.take(opts, [
      :beaver_revision,
      :dialect_schema_digest,
      :runtime_abi_digest,
      :target
    ])
  end

  defp write_bootstrap_receipt!(
         output_dir,
         bootstrap,
         kernel_identity,
         lowered_ir_digest,
         object_path
       ) do
    path = Path.join(output_dir, "bootstrap-receipt.json")

    receipt = %{
      "schema_version" => 1,
      "stage" => Map.fetch!(bootstrap, "stage"),
      "seed" => Map.fetch!(bootstrap, "seed"),
      "provenance" => Map.fetch!(bootstrap, "provenance"),
      "source_kernel_identity" => Map.fetch!(bootstrap, "source_kernel_identity"),
      "kernel_identity" => kernel_identity,
      "lowered_ir_sha256" => lowered_ir_digest,
      "object_sha256" => digest_file!(object_path)
    }

    File.write!(path, Memory.canonical_json(receipt) <> "\n")
    path
  end

  defp digest_file!(path) do
    "sha256:" <>
      (path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
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
