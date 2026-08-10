defmodule Batata.Transform.ExpandCase do
  @moduledoc """
  Expands `ex.case` into nested `ex.if`/`ex.cmp` before dialect conversion.

  Delegates to `Beaver.MLIR.Dialect.Ex.ExpandCase` (multi-pattern clauses and
  guard narrowing live in Beaver); this pass plugs it into the batata
  transform pipeline.
  """

  alias Beaver.MLIR
  alias Beaver.MLIR.Dialect.Ex.ExpandCase

  @behaviour Batata.Transform.Pass

  @impl Batata.Transform.Pass
  def run!(%MLIR.Module{} = module) do
    ExpandCase.run!(module)
  end
end
