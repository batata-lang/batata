defmodule Batata.Transform do
  @moduledoc """
  IR-to-IR rewrite layer between the frontend lift and lowering.

  Discipline (transplanted from expandable): a transform never changes the
  representation or drops information; anything that changes representation
  or drops information belongs in `Batata.Lower`. Passes rewrite `ex` IR in
  place through Beaver rewriters.

  `run!/2` applies each pass module to the module in order.
  """

  alias Beaver.MLIR

  @doc "Applies `passes` (modules implementing `Batata.Transform.Pass`) in order."
  @spec run!(MLIR.Module.t(), [module()]) :: MLIR.Module.t()
  def run!(%MLIR.Module{} = module, passes) do
    Enum.each(passes, & &1.run!(module))
    module
  end
end

defmodule Batata.Transform.Pass do
  @moduledoc """
  Behaviour for `Batata.Transform` passes.

  A pass rewrites the module in place and returns the module. It must stay
  information-preserving: no representation change and no information loss.
  """

  @callback run!(Beaver.MLIR.Module.t()) :: Beaver.MLIR.Module.t()
end
