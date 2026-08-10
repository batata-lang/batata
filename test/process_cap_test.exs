defmodule Batata.ProcessCapTest do
  # Not async: concurrent `Batata.execute` runs share the implicit runtime's
  # process table in this slice, so many-spawn tests would race with other
  # tests' executions.
  use Batata.Case, async: false

  alias Batata

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
end
