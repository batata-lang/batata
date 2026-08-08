defmodule Batata.LowerTest do
  use Batata.Case, async: true

  alias Batata

  test "lowers the scalar slice from ex IR to func/arith and LLVM", %{ctx: ctx} do
    module =
      Batata.to_llvm(
        """
        defmodule Math do
          def main() do
            a = 1 + 2
            a + 3
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module)
    refute rendered =~ "ex."
    assert rendered =~ "llvm.func"
    assert rendered =~ "llvm.add"
  end

  test "lowers a non-scalar local call into a func.call", %{ctx: ctx} do
    module =
      Batata.to_llvm(
        """
        defmodule Math do
          def main() do
            helper()
          end

          def helper() do
            {1, 2}
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module)
    refute rendered =~ ~s{"ex.}
    assert rendered =~ "llvm.func"
  end
end
