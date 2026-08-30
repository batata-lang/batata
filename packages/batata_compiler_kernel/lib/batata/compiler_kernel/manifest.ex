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
    ex.box
    ex.call
    ex.cmp
    ex.div
    ex.exported_clone
    ex.exported_destroy
    ex.exported_get
    ex.exported_length
    ex.func
    ex.if
    ex.is_atom
    ex.is_binary
    ex.is_float
    ex.is_integer
    ex.is_list
    ex.is_map
    ex.is_tuple
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
    ex.self
    ex.send
    ex.receive
    ex.mailbox_clear
    ex.spawn
    ex.schedule_next
    ex.current_entry
    ex.process_done
    ex.process_exit
    ex.process_exit_reason
    ex.process_trap_exit
    ex.link
    ex.list
    ex.unlink
    ex.exit
    ex.monitor
    ex.demonitor
    ex.processes_runnable
    ex.process_result
    ex.cont_save
    ex.receive_cont_save
    ex.cont_pending
    ex.cont_active
    ex.cont_clear
    ex.cont_load_arg
    ex.cont_load_acc
    ex.cont_load_cursor
    ex.clock_init
    ex.reduction_tick
    ex.yield_mark
    ex.mailbox_len
    ex.mailbox_peek
    ex.mailbox_remove
    ex.map
    ex.nil_word
    ex.monotonic_time
    ex.receive_start
    ex.receive_start_set
    ex.native_time
    ex.unique_integer
    ex.to_int
    ex.term_eq_loose
    ex.list_flatten
    ex.list_head
    ex.list_tail
    ex.list_get
    ex.list_length
    ex.tuple_get
    ex.tuple_length
    ex.map_fetch
    ex.map_put
    ex.map_length
    ex.mapset_from_list
    ex.mapset_member
    ex.mapset_put
    ex.binary_from_list
    ex.iodata_to_binary
    ex.float_lit
    ex.string_to_float
    ex.string_to_atom
    ex.string_to_existing_atom
    ex.float_to_binary_short
    ex.binary_length
    ex.binary_get
    ex.binary_slice
    ex.binary_utf8_get
    ex.binary_utf8_width
    ex.binary_utf8_length
    ex.string_printable
    ex.binary_quote
    ex.binary_encode16
    ex.binary_decode16
    ex.int_to_string
    ex.int_to_string_base
    ex.int_to_hex
    ex.string_to_int
    ex.file_read
    ex.file_read_lines
    ex.enumerable_count
    ex.enumerable_to_list
    ex.enumerable_into_map
    ex.enumerable_intersperse
    ex.enumerable_to_list_range
    ex.enumerable_reduce
    ex.enumerable_reduce_c
    ex.enumerable_reduce_range
    ex.enumerable_reduce_fun
    ex.enumerable_map_fun
    ex.enumerable_map_term_fun
    ex.enumerable_map_term_fun_c
    ex.enumerable_flat_map_term_fun
    ex.stream_filter
    ex.stream_take
    ex.stream_drop
    ex.fun_arity
    ex.fun_result_mode
    ex.list_cons
    ex.process_wait
    ex.worker_run
    ex.catch_value
    ex.throw
    ex.raise
    ex.sub
    ex.term_eq
    ex.term_export
    ex.term_handle_destroy
    ex.term_handle_export
    ex.term_import
    ex.to_word
    ex.tuple
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
    "ir.type.v1",
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
