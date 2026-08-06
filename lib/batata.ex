defmodule Batata do
  @moduledoc """
  An Elixir-to-native compiler built on [Beaver](https://github.com/beaver-lodge/beaver)
  and the Slang-defined `ex` dialect.

  M1 brings up the frontend boundary (expanded module snapshot to `ex` IR),
  `ex` to `func`/`arith`/`scf`/`cf` to LLVM lowering via
  `Beaver.MLIR.Conversion.Plan`, and ExecutionEngine / AOT execution.
  """
end
