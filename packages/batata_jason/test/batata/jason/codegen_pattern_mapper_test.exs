defmodule Batata.Probe.Jason.CodegenPatternMapperTest do
  @moduledoc """
  Executable callback kernels derived from `Jason.Codegen` in Jason 1.4.5.

  They cover tuple-pattern `Enum.map/2` and `Enum.flat_map/2` boundaries used
  by literal and jump-table generation, plus the captured shorthand mapper in
  `build_kv_iodata/2`, including its nested-list flatten and static binary
  collapse pipeline.
  """

  use Batata.Jason.Case, async: true

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

  @captured_source """
  defmodule JasonCodegenCapturedMapperKernel do
    def encode_pair({key, value}, _encode_args), do: {key, value}

    def build_kv_iodata(kv, encode_args) do
      kv
      |> Enum.map(&encode_pair(&1, encode_args))
      |> Enum.intersperse(",")
    end

    def main() do
      build_kv_iodata([{"one", 1}, {"two", 2}], [:escape, :encode_map])
    end
  end
  """

  @build_kv_source """
  defmodule JasonCodegenBuildKvKernel do
    def encode_pair({key, value}, _encode_args), do: [key, value]

    def collapse_static([bin1, bin2 | rest]) when is_binary(bin1) and is_binary(bin2) do
      collapse_static([bin1 <> bin2 | rest])
    end

    def collapse_static([other | rest]), do: [other | collapse_static(rest)]
    def collapse_static([]), do: []

    def build_kv_iodata(kv, encode_args) do
      elements =
        kv
        |> Enum.map(&encode_pair(&1, encode_args))
        |> Enum.intersperse(",")

      collapse_static(List.flatten(["{", elements, 125]))
    end

    def main() do
      build_kv_iodata([{"\\\"a\\\":", "1"}, {"\\\"b\\\":", "2"}], [:escape])
    end
  end
  """

  test "preserves tagged tuple inputs and mapper results", %{ctx: ctx} do
    expected = beam_result(@source)
    assert expected == Batata.execute(@source, ctx)
  end

  test "threads the build_kv_iodata capture through a piped shorthand mapper", %{ctx: ctx} do
    expected = beam_result(@captured_source)
    assert expected == Batata.execute(@captured_source, ctx)
  end

  test "flattens and collapses the complete build_kv_iodata pipeline", %{ctx: ctx} do
    expected = beam_result(@build_kv_source)
    assert expected == Batata.execute(@build_kv_source, ctx)
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
