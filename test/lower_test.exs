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
    refute rendered =~ "\"ex."
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

  test "injects the physical arena quota at the Lower boundary", %{ctx: ctx} do
    module =
      Batata.compile(
        """
        defmodule Quota do
          def main(), do: [1, 2]
        end
        """,
        ctx,
        memory_quota_bytes: 4_096
      )

    rendered =
      module
      |> Batata.Lower.to_func(memory_quota_bytes: 4_096)
      |> MLIR.to_string()

    assert rendered =~ "call @ex.term.runtime_set_arena_limit"
    assert rendered =~ "arith.constant 4096 : i64"
    assert rendered =~ "func.func private @ex.term.runtime_set_arena_limit(i64, i64) -> i64"

    assert index(rendered, "ex.term.runtime_create") <
             index(rendered, "ex.term.runtime_set_arena_limit")

    assert index(rendered, "ex.term.runtime_set_arena_limit") <
             index(rendered, "ex.term.runtime_enter")
  end

  defp index(text, pattern) do
    {offset, _length} = :binary.match(text, pattern)
    offset
  end
end
