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

    if request_c_wrappers? do
      module
      |> Beaver.Composer.nested("func.func", "llvm-request-c-wrappers")
      |> Beaver.Composer.run!()
    end

    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionConvertFuncToLLVMPass/0)

    module
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
