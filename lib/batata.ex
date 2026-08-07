defmodule Batata do
  @moduledoc """
  An Elixir-to-native compiler built on [Beaver](https://github.com/beaver-lodge/beaver)
  and the Slang-defined `ex` dialect.

  The frontend boundary lowers an expanded module snapshot to `ex` IR, then
  `ex` to `func`/`arith`/`scf`/`cf` and finally to LLVM via
  `Beaver.MLIR.Conversion.Plan`. ExecutionEngine / AOT execution is still
  pending.
  """

  alias Beaver.MLIR

  @doc """
  Parses and lowers Elixir source into a verified `builtin.module` of `ex`
  operations.
  """
  @spec compile(String.t(), MLIR.Context.t()) :: MLIR.Module.t()
  def compile(source, ctx) do
    source
    |> Batata.Frontend.from_source()
    |> Batata.Lift.module_to_ir(ctx: ctx)
    |> Beaver.Deferred.create(ctx)
    |> MLIR.verify!()
  end

  @doc """
  Parses Elixir source and lowers it all the way to LLVM dialect IR.
  """
  @spec to_llvm(String.t(), MLIR.Context.t()) :: MLIR.Module.t()
  def to_llvm(source, ctx) do
    source
    |> compile(ctx)
    |> Batata.Lower.to_llvm(ctx)
    |> MLIR.verify!()
  end

  @doc """
  Parses Elixir source, lowers it to LLVM and executes `main` through the
  MLIR JIT, returning its value.

  The JIT engine and module are destroyed before returning.
  """
  @spec execute(String.t(), MLIR.Context.t()) :: term()
  def execute(source, ctx) do
    module =
      source
      |> compile(ctx)
      |> Batata.Lower.to_llvm(ctx, c_interface: true)
      |> MLIR.verify!()

    jit = MLIR.ExecutionEngine.create!(module)

    try do
      return = Beaver.Native.I64.make(0)
      MLIR.ExecutionEngine.invoke!(jit, "main", [], return)
      Beaver.Native.to_term(return)
    after
      MLIR.ExecutionEngine.destroy(jit)
      MLIR.Module.destroy(module)
    end
  end
end
