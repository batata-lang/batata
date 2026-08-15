defmodule Batata.RuntimeStressTest do
  use Batata.Case, async: true

  @moduletag timeout: 180_000
  @boundary_sizes [1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 257, 1024]

  test "binary and list conversions match BEAM across allocation boundaries", %{ctx: ctx} do
    Enum.each(@boundary_sizes, fn size ->
      binary = pattern_binary(size)
      list = :binary.bin_to_list(binary)

      expression =
        "{" <>
          "Enum.to_list(#{inspect(binary, limit: :infinity)})," <>
          ":erlang.list_to_binary(#{inspect(list, charlists: :as_lists, limit: :infinity)})," <>
          "IO.iodata_to_binary([#{inspect(binary, limit: :infinity)}, [0, 1, 127, 128, 255]])" <>
          "}"

      expected = {list, binary, binary <> <<0, 1, 127, 128, 255>>}
      assert Batata.execute(source(expression), ctx) == expected, "size=#{size}"
    end)
  end

  test "empty conversion boundaries match BEAM without erasing list identity", %{ctx: ctx} do
    expression =
      "{:erlang.list_to_binary([]), IO.iodata_to_binary([\"\", [0, 1, 127, 128, 255]])}"

    assert Batata.execute(source(expression), ctx) == {"", <<0, 1, 127, 128, 255>>}
  end

  test "binary enumeration remains stable under low scheduler budgets", %{ctx: ctx} do
    binary = pattern_binary(257)
    expression = "Enum.to_list(#{inspect(binary, limit: :infinity)})"
    expected = :binary.bin_to_list(binary)
    compiled_source = source(expression)

    assert Batata.execute(compiled_source, ctx, reduction_budget: 1) == expected
    assert Batata.execute(compiled_source, ctx, reduction_budget: 2) == expected
  end

  test "nested iodata matches BEAM", %{ctx: ctx} do
    nested =
      Enum.reduce(0..7, <<0, 1, 127, 128, 255>>, fn byte, acc ->
        [byte, acc]
      end)

    expression =
      "IO.iodata_to_binary(#{inspect(nested, charlists: :as_lists, limit: :infinity)})"

    expected = IO.iodata_to_binary(nested)
    assert Batata.execute(source(expression), ctx) == expected
  end

  defp pattern_binary(0), do: <<>>

  defp pattern_binary(size),
    do: for(index <- 0..(size - 1), into: <<>>, do: <<rem(index * 131 + 255, 256)>>)

  defp source(expression) do
    """
    defmodule RuntimeStressBinaryList do
      def main() do
        #{expression}
      end
    end
    """
  end
end
