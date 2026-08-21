defmodule Batata.Probe.Jason.CodegenPatternMapperTest do
  @moduledoc """
  Executable callback kernels derived from `Jason.Codegen` in Jason 1.4.5.

  They cover the capture-free tuple-pattern `Enum.map/2` and
  `Enum.flat_map/2` boundaries used by literal and jump-table generation.
  """

  use Batata.Case, async: true

  alias Batata

  @source """
  defmodule JasonCodegenPatternMapperKernel do
    def literal_clauses(clauses) do
      Enum.map(clauses, fn {:->, _, [[literal], action]} ->
        {literal, action}
      end)
    end

    def jump_table_clauses(literals) do
      Enum.flat_map(literals, fn {pattern, action} ->
        [{:clause, pattern, action}]
      end)
    end

    def main() do
      {
        literal_clauses([{:->, [], [[1], :one]}, {:->, [], [[2], :two]}]),
        jump_table_clauses([{1, :one}, {2, :two}])
      }
    end
  end
  """

  test "preserves tagged tuple inputs and mapper results", %{ctx: ctx} do
    expected = beam_result(@source)
    assert expected == Batata.execute(@source, ctx)
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
