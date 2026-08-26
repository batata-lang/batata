defmodule Batata.BitwiseTest do
  use Batata.Case, async: true

  test "executes the imported Bitwise cluster against the BEAM oracle", %{ctx: ctx} do
    source = """
    defmodule BitwiseOracle do
      import Bitwise

      def main() do
        {
          -5 &&& 3,
          16 ||| 3,
          bxor(29, 15),
          3 <<< 4,
          -64 >>> 2,
          bnot(5),
          band(29, 15),
          bor(16, 3),
          bsl(3, 4),
          bsr(-64, 2)
        }
      end
    end
    """

    {expected, _binding} = Code.eval_string(source <> "\nBitwiseOracle.main()")
    assert Batata.execute(source, ctx) == expected
  end

  test "executes a qualified Jason-shaped shift and mask composition", %{ctx: ctx} do
    source = """
    defmodule JasonBitwiseSlice do
      import Bitwise, only: [&&&: 2, |||: 2, <<<: 2, >>>: 2]

      def main() do
        first = 0xD8
        last = 0x34
        char = ((first &&& 0x3F) <<< 10) ||| (last &&& 0x3FF)
        0x800 ||| (char >>> 10)
      end
    end
    """

    {expected, _binding} = Code.eval_string(source <> "\nJasonBitwiseSlice.main()")
    assert Batata.execute(source, ctx) == expected
  end
end
