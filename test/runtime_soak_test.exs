defmodule Batata.RuntimeSoakTest do
  # MLIR compilation is CPU-heavy and process-global LLVM resources are not a
  # useful thing to oversubscribe with the rest of the async suite. The test
  # itself still submits two concurrent sessions. Their engine lifetimes are
  # serialized because MLIR resolves same-named C wrappers process-globally;
  # each session still runs four native actor workers in parallel.
  use ExUnit.Case, async: false

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

  test "concurrent JIT submissions keep actor results runtime-local" do
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

  test "concurrent composite results stay bound to their creating engine" do
    source = """
    defmodule CompositeSession do
      def main(), do: {1, [2, 3], %{7 => 42}, <<4, 5>>}
    end
    """

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          ctx = MLIR.Context.create()

          try do
            Batata.execute(source, ctx)
          after
            MLIR.Context.destroy(ctx)
          end
        end,
        max_concurrency: 4,
        timeout: 180_000
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert results == List.duplicate({1, [2, 3], %{7 => 42}, <<4, 5>>}, 8)
  end
end
