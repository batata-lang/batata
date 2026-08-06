defmodule Batata do
  @moduledoc """
  An Elixir-to-native compiler built on [Beaver](https://github.com/beaver-lodge/beaver)
  and the Slang-defined `ex` dialect.

  M1 brings up the frontend boundary (expanded module snapshot to `ex` IR),
  `ex` to `func`/`arith`/`scf`/`cf` to LLVM lowering via
  `Beaver.MLIR.Conversion.Plan`, and ExecutionEngine / AOT execution.
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
end
