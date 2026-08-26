defmodule Batata.Probe.Jason.CodegenIntersperseTest do
  @moduledoc """
  Executable nested-iodata kernel derived from
  `Jason.Codegen.build_kv_iodata/2` in Jason 1.4.5.

  This isolates the `Enum.intersperse/2` boundary from the callback and macro
  blockers that still prevent the unmodified `Jason.Codegen` module from
  compiling as a unit.
  """

  use Batata.Jason.Case, async: true

  alias Batata

  @source """
  defmodule JasonCodegenIntersperseKernel do
    def build_kv_iodata(elements) do
      IO.iodata_to_binary(["{", Enum.intersperse(elements, ","), "}"])
    end

    def main() do
      build_kv_iodata([["\\\"a\\\"", ":", "1"], ["\\\"b\\\"", ":", "2"]])
    end
  end
  """

  test "preserves pair iodata and inserts commas", %{ctx: ctx} do
    assert ~s({"a":1,"b":2}) == beam_result(@source)
    assert ~s({"a":1,"b":2}) == Batata.execute(@source, ctx)
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
