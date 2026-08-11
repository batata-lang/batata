defmodule Batata.Lower do
  @moduledoc """
  Lowers `ex` dialect IR to `func`/`arith`/`scf`/`cf` and then to LLVM.

  The conversion patterns live in Beaver
  (`Beaver.MLIR.Conversion.Ex`); this module wires them together with the
  standard `arith-to-llvm` and `func-to-llvm` passes for the lowering phase.
  """

  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Ex, as: ExConversion
  alias Beaver.MLIR.Conversion.Plan
  alias Beaver.Walker

  @doc """
  Converts an `ex` dialect module to `func`/`arith`/`scf`/`cf`.

  The module is converted in place and returned.
  """
  @spec to_func(MLIR.Module.t()) :: MLIR.Module.t()
  def to_func(module) do
    Plan.run!(ExConversion.plan(), module)
  end

  @doc """
  Lowers an `ex` dialect module to LLVM dialect IR.

  Runs the ex conversion plan followed by the standard `arith-to-llvm` and
  `func-to-llvm` passes. With `c_interface: true`, requests C wrappers on the
  functions (`llvm-request-c-wrappers`) between the passes so they can be
  invoked through the MLIR JIT (`Beaver.MLIR.ExecutionEngine`). The module is
  converted in place and returned.
  """
  @spec to_llvm(MLIR.Module.t(), MLIR.Context.t(), keyword()) :: MLIR.Module.t()
  def to_llvm(module, ctx, opts \\ []) do
    module = to_func(module)
    request_c_wrappers? = Keyword.get(opts, :c_interface, false)

    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionArithToLLVMConversionPass/0)
    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionSCFToControlFlowPass/0)
    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionConvertControlFlowToLLVMPass/0)

    if request_c_wrappers? do
      request_c_wrappers_for_entries(module, [
        "main",
        "__batata_result_destroy",
        "__batata_result_root_kind",
        "__batata_result_root_word",
        "__batata_result_term_kind",
        "__batata_result_term_length",
        "__batata_result_term_get",
        "__batata_term_export",
        "__batata_term_import",
        "__batata_exported_clone",
        "__batata_exported_destroy",
        "__batata_exported_length",
        "__batata_exported_get",
        "__batata_term_handle_export",
        "__batata_term_handle_destroy"
      ])
    end

    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionConvertFuncToLLVMPass/0)

    module
  end

  # Asks func-to-llvm to emit a C interface wrapper (`_mlir_ciface_*`) only for
  # the entry function. The Zig term runtime declarations must not get
  # wrappers: the generated `_mlir_ciface_*` symbols have no body and would
  # fail JIT materialization.
  defp request_c_wrappers_for_entries(module, sym_names) do
    module
    |> MLIR.Module.body()
    |> Walker.operations()
    |> Enum.filter(fn op ->
      MLIR.Operation.name(op) == "func.func" and symbol_name(op) in sym_names
    end)
    |> Enum.each(fn entry ->
      MLIR.Operation.get_and_update(entry, "llvm.emit_c_interface", fn _ ->
        {nil, MLIR.Attribute.unit()}
      end)
    end)

    module
  end

  defp symbol_name(op) do
    case op |> MLIR.Operation.fetch("sym_name") do
      {:ok, attribute} -> attribute |> MLIR.CAPI.mlirStringAttrGetValue() |> MLIR.to_string()
      :error -> nil
    end
  end

  defp run_pass(module, ctx, pass_fun) do
    pass_manager = MLIR.CAPI.mlirPassManagerCreate(ctx)

    try do
      MLIR.CAPI.mlirPassManagerAddOwnedPass(pass_manager, pass_fun.())
      {:ok, _} = MLIR.PassManager.run(pass_manager, module)
    after
      MLIR.PassManager.destroy(pass_manager)
    end

    module
  end
end
