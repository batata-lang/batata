defmodule Batata.RuntimeActorStressTest do
  use Batata.Case, async: false

  @moduletag timeout: 180_000

  test "tuple and map boundaries match BEAM", %{ctx: ctx} do
    tuple = 0..63 |> Enum.to_list() |> List.to_tuple()

    map =
      Map.new(0..63, fn key ->
        {key, {key, <<rem(key * 131 + 255, 256)>>}}
      end)

    tuple_source = inspect(tuple, limit: :infinity)
    map_source = inspect(map, limit: :infinity)
    inserted = {64, <<63>>}

    expression = """
    tuple = #{tuple_source}
    map = Map.put(#{map_source}, 64, #{inspect(inserted)})
    {tuple_size(tuple), elem(tuple, 0), elem(tuple, 63), Map.size(map), map}
    """

    expected_map = Map.put(map, 64, inserted)
    expected = {64, 0, 63, 65, expected_map}
    assert Batata.execute(source("TupleMapStress", expression), ctx) == expected
  end

  test "parallel actors preserve composite messages while the process table grows", %{ctx: ctx} do
    spawns =
      1..24
      |> Enum.map_join("\n", fn value ->
        "spawn(fn -> send(parent, {#{value}, [#{value}], <<63>>}) end)"
      end)

    source = """
    defmodule CompositeMailboxStress do
      def collect(0, acc), do: acc

      def collect(remaining, acc) do
        value = receive do
          _message -> 1
        end

        collect(remaining - 1, acc + value)
      end

      def main() do
        parent = self()
        #{spawns}
        collect(24, 0)
      end
    end
    """

    expected = 24

    assert Batata.execute(
             source,
             ctx,
             workers: 4,
             process_cap: 2,
             reduction_budget: 2
           ) == expected
  end

  defp source(module, expression) do
    """
    defmodule #{module} do
      def main() do
        #{expression}
      end
    end
    """
  end
end
