defmodule Batata.CompilerKernel.Performance do
  @moduledoc """
  Produces bounded Stage 0 versus Stage 2 conversion performance receipts.

  The corpus contains only frozen-seed scalar roots, so both providers must be
  callback-free. Timing and memory values are observations rather than a
  brittle percentage gate; canonical IR parity and the zero-callback boundary
  are hard requirements.
  """

  alias Batata.CompilerKernel.Provider
  alias Batata.Memory
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Ex, as: ExConversion
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest
  alias Beaver.MLIR.Conversion.Plan

  @doc "Profiles a fixed scalar scaling curve and writes one canonical receipt."
  @spec profile!(map(), MLIR.Context.t(), Path.t(), keyword()) :: map()
  def profile!(stage2, ctx, receipt_path, opts)
      when is_map(stage2) and is_binary(receipt_path) and is_list(opts) do
    sizes = Keyword.fetch!(opts, :sizes)
    validate_sizes!(sizes)
    manifest = Map.fetch!(stage2, :kernel_manifest)
    library = Map.fetch!(stage2, :library)

    native_plan =
      Provider.production_plan!(manifest, library,
        beaver_revision: Keyword.fetch!(opts, :beaver_revision),
        dialect_schema_digest: Keyword.fetch!(opts, :dialect_schema_digest),
        runtime_abi_digest: Keyword.fetch!(opts, :runtime_abi_digest),
        target: Keyword.fetch!(opts, :target)
      )

    samples = Enum.map(sizes, &profile_size(&1, ctx, native_plan))

    receipt = %{
      "schema_version" => 1,
      "corpus" => "frozen-stage0-scalar-chain-v1",
      "kernel_identity" => KernelManifest.identity_digest(manifest),
      "callback_free" => true,
      "sizes" => sizes,
      "samples" => samples
    }

    File.write!(receipt_path, Memory.canonical_json(receipt) <> "\n")
    receipt
  end

  defp profile_size(size, ctx, native_plan) do
    stage0_module = scalar_module(ctx, size)
    stage2_module = scalar_module(ctx, size)

    try do
      {^stage0_module, stage0} = Plan.profile!(ExConversion.plan(), stage0_module)
      {^stage2_module, stage2} = Plan.profile!(native_plan, stage2_module)
      require_callback_free!(stage0, "cpp-bootstrap")
      require_callback_free!(stage2, "native-kernel")

      stage0_ir = MLIR.to_string(stage0_module, generic: true)
      stage2_ir = MLIR.to_string(stage2_module, generic: true)

      unless stage0_ir == stage2_ir do
        raise "Stage 0 and Stage 2 performance corpus produced different canonical IR"
      end

      %{
        "size" => size,
        "canonical_ir_sha256" => digest(stage2_ir),
        "stage0" => stage0,
        "stage2" => stage2
      }
    after
      MLIR.Module.destroy(stage0_module)
      MLIR.Module.destroy(stage2_module)
    end
  end

  defp scalar_module(ctx, size) do
    additions =
      1..size
      |> Enum.map_join("\n", fn index ->
        previous = index - 1
        ~s|%#{index} = "ex.add"(%#{previous}, %0) : (i64, i64) -> i64|
      end)

    MLIR.Module.create!(
      """
      module {
        func.func @scalar_chain() -> i64 {
          %0 = "ex.lit"() {value = 1 : i64} : () -> i64
          #{additions}
          func.return %#{size} : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp require_callback_free!(conversion, provider) do
    unless conversion["status"] == "ok" and
             conversion["beam"]["callback_count"] == 0 and
             conversion["beam"]["max_in_flight"] == 0 and
             conversion["callbacks"] == [] do
      raise "#{provider} crossed the BEAM callback boundary in the performance corpus"
    end
  end

  defp validate_sizes!(sizes)
       when is_list(sizes) and sizes != [] do
    unless Enum.all?(sizes, &(is_integer(&1) and &1 > 0)) and
             sizes == Enum.sort(Enum.uniq(sizes)) do
      raise ArgumentError, "profile sizes must be sorted unique positive integers"
    end
  end

  defp validate_sizes!(_sizes) do
    raise ArgumentError, "profile sizes must be a non-empty list"
  end

  defp digest(bytes) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
  end
end
