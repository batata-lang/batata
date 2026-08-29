defmodule Batata.UnusedBranchAliasTest do
  use Batata.Case, async: true, group: :execution_engine

  @source """
  defmodule UnusedBranchAliasFixture do
    defp pp_string(_rest, _output, in_bs, _cont), do: if(in_bs, do: 1, else: 0)

    def format(byte, rest, output, depth, _empty, opts) do
      if byte == ?" do
        pp_string(rest, output, _in_bs = false, depth)
      else
        pp_string(rest, opts, _in_bs = true, depth)
      end
    end

    def wildcard(flag, value), do: if(flag, do: (_ = value), else: (_ = false))

    def main() do
      {
        format(?", 10, 20, 2, true, 3),
        format(?x, 11, 21, 3, false, 4),
        wildcard(true, 7),
        wildcard(false, 7)
      }
    end
  end
  """

  test "normalizes unread underscore aliases inside selected if branches", %{ctx: ctx} do
    expected =
      @source
      |> Kernel.<>("\nUnusedBranchAliasFixture.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(@source, ctx) == expected
  end

  test "retains body-if control flow after alias normalization", %{ctx: ctx} do
    ir = @source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)
    assert ir =~ ~s{"ex.if"}
    assert ir =~ ~s{"ex.term_eq"}
  end

  test "keeps branch assignments local to their selected region", %{ctx: ctx} do
    source = """
    defmodule EnvironmentBearingBranchAssignment do
      def choose(flag) do
        value = 10

        branch =
          if flag do
            value = 1
            value + 1
          else
            value = 3
            value + 1
          end

        {value, branch}
      end

      def main(), do: {choose(true), choose(false)}
    end
    """

    assert {{10, 2}, {10, 4}} == Batata.execute(source, ctx)
  end
end
