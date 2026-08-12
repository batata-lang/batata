defmodule Batata.ProcessCapTest do
  use Batata.Case, async: true

  alias Batata
  alias Beaver.MLIR

  test "spawn grows the process table beyond the initial capacity (#50 stage 2)", %{ctx: ctx} do
    spawns =
      for i <- 1..24 do
        "spawn(fn -> send(me, #{i}) end)"
      end
      |> Enum.join("\n")

    source = """
    defmodule M do
      def recv(0, acc), do: acc

      def recv(n, acc) do
        x = receive do
          v when is_integer(v) -> v
        end

        recv(n - 1, acc + x)
      end

      def main() do
        me = self()
        #{spawns}
        recv(24, 0)
      end
    end
    """

    # With an initial capacity of 2, the table must grow to host all 24
    # short-lived actors; every actor's message arrives.
    # A reduction budget lets the entry's receive scan yield to the spawned
    # actors before consuming the mailbox.
    assert 300 == Batata.execute(source, ctx, process_cap: 2, reduction_budget: 2)
  end

  test "a small initial capacity still lets every spawned process run (#50 stage 2)", %{ctx: ctx} do
    # cap = 2: both spawned actors run (the table grows), the FIFO receive
    # matches the first delivered message (7).
    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   me = self()
                   spawn(fn -> send(me, 7) end)
                   spawn(fn -> send(me, 8) end)

                   receive do
                     7 -> 0
                     _ -> 1
                   after
                     :infinity -> 2
                   end
                 end
               end
               """,
               ctx,
               process_cap: 2,
               reduction_budget: 2
             )
  end

  @tag timeout: 180_000
  test "concurrent execute calls isolate dynamically grown process tables" do
    results =
      1..8
      |> Task.async_stream(
        fn base ->
          ctx = MLIR.Context.create()

          source = """
          defmodule ConcurrentActors#{base} do
            def sum(0, acc), do: acc

            def sum(n, acc) do
              value = receive do
                value when is_integer(value) -> value
              end

              sum(n - 1, acc + value)
            end

            def main() do
              parent = self()
              spawn(fn -> send(parent, #{base + 1}) end)
              spawn(fn -> send(parent, #{base + 2}) end)
              spawn(fn -> send(parent, #{base + 3}) end)
              spawn(fn -> send(parent, #{base + 4}) end)
              sum(4, 0)
            end
          end
          """

          try do
            Batata.execute(source, ctx, process_cap: 2, reduction_budget: 2)
          after
            MLIR.Context.destroy(ctx)
          end
        end,
        max_concurrency: 8,
        timeout: 120_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.sort()

    assert results == Enum.map(1..8, &(4 * &1 + 10))
  end
end
