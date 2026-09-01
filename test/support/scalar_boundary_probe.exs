Application.ensure_all_started(:batata)
Application.put_env(:batata, :conversion_provider, :cpp_bootstrap)

alias Beaver.MLIR

source = """
defmodule InvalidScalarBoundaryProbe do
  def maximum(left, right), do: Kernel.max(left, right)
  def main(), do: maximum("a", "b")
end
"""

ctx = MLIR.Context.create()

try do
  try do
    Batata.execute(source, ctx)
    IO.puts("unexpected success")
    System.halt(2)
  rescue
    ArgumentError -> IO.puts("caught ArgumentError")
  end
after
  MLIR.Context.destroy(ctx)
end
