defmodule Batata.LowerTest do
  use ExUnit.Case, async: true

  alias Batata
  alias Beaver.MLIR

  defp with_ctx(fun) do
    ctx = MLIR.Context.create()

    try do
      fun.(ctx)
    after
      MLIR.Context.destroy(ctx)
    end
  end

  test "lowers the M1 scalar slice from ex IR to func/arith and LLVM" do
    with_ctx(fn ctx ->
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
    end)
  end

  test "lowers a local call into a func.call" do
    with_ctx(fn ctx ->
      module =
        Batata.to_llvm(
          """
          defmodule Math do
            def main() do
              helper()
            end

            def helper() do
              1
            end
          end
          """,
          ctx
        )

      rendered = MLIR.to_string(module)
      refute rendered =~ "ex."
      assert rendered =~ "llvm.func"
    end)
  end
end
