defmodule Batata.RuntimeSoakTest do
  use ExUnit.Case, async: true

  alias Beaver.MLIR

  @moduletag timeout: 180_000

  @fan_in_source """
  defmodule FanIn do
    def main() do
      me = self()
      spawn(fn -> send(me, 10) end)
      spawn(fn -> send(me, 20) end)
      sum = Enum.reduce([1, 2, 3, 4, 5], 0, fn x, acc -> x + acc end)

      first = receive do
        10 -> 10
      end

      second = receive do
        20 -> 20
      end

      sum + first + second
    end
  end
  """

  test "concurrent JIT sessions keep actor results runtime-local" do
    results =
      1..2
      |> Task.async_stream(
        fn _ ->
          ctx = MLIR.Context.create()

          try do
            Batata.execute(@fan_in_source, ctx,
              workers: 4,
              process_cap: 2,
              reduction_budget: 2
            )
          after
            MLIR.Context.destroy(ctx)
          end
        end,
        max_concurrency: 2,
        ordered: false,
        timeout: 180_000
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert results == [45, 45]
  end
end
