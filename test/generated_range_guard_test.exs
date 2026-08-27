defmodule Batata.GeneratedRangeGuardTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Beaver.MLIR

  @source """
  defmodule GeneratedRangeGuard do
    def classify(byte) when byte in 0..31, do: byte
    def classify(byte) when byte in 120..127, do: byte
    def classify(_byte), do: -1

    def main() do
      classify(0) + classify(31) + classify(123) + classify(32)
    end
  end
  """

  test "executes expanded unit-range guards against the BEAM oracle", %{
    ctx: ctx
  } do
    expected = beam_result(@source)

    assert expected == 153
    assert expected == Batata.execute(@source, ctx)
  end

  test "emits verified integer comparisons for expanded range guards", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    assert MLIR.verify?(module)

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "ex.is_integer"
    assert rendered =~ "ex.to_int"
    assert rendered =~ "ex.cmp"
  end

  defp beam_result(source) do
    [{module, _binary}] = Code.compile_string(source)

    try do
      module.main()
    after
      :code.purge(module)
      :code.delete(module)
    end
  end
end
