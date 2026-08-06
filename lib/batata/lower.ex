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
  `func-to-llvm` passes. The module is converted in place and returned.
  """
  @spec to_llvm(MLIR.Module.t(), MLIR.Context.t()) :: MLIR.Module.t()
  def to_llvm(module, ctx) do
    module = to_func(module)

    pass_manager = MLIR.CAPI.mlirPassManagerCreate(ctx)

    try do
      MLIR.CAPI.mlirPassManagerAddOwnedPass(
        pass_manager,
        MLIR.CAPI.mlirCreateConversionArithToLLVMConversionPass()
      )

      MLIR.CAPI.mlirPassManagerAddOwnedPass(
        pass_manager,
        MLIR.CAPI.mlirCreateConversionConvertFuncToLLVMPass()
      )

      {:ok, _} = MLIR.PassManager.run(pass_manager, module)
    after
      MLIR.PassManager.destroy(pass_manager)
    end

    module
  end
end
