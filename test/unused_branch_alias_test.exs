defmodule Batata.UnusedBranchAliasTest do
  use Batata.Case, async: true

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

  test "keeps environment-bearing branch assignments fail-closed", %{ctx: ctx} do
    for branch <- [
          "value = 1",
          "(_value = 1; _value)"
        ] do
      source = """
      defmodule EnvironmentBearingBranchAssignment do
        def main(), do: if(true, do: (#{branch}), else: 0)
      end
      """

      assert_raise Batata.Lift.Error,
                   "assignments in if branches are unsupported",
                   fn -> Batata.compile(source, ctx) end
    end
  end
end
