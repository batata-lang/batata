defmodule Batata.ExecuteTest do
  use Batata.Case, async: true

  alias Batata

  test "executes a compiled module through the JIT", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   1 + 2
                 end
               end
               """,
               ctx
             )
  end

  test "executes bindings", %{ctx: ctx} do
    assert 6 ==
             Batata.execute(
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
  end

  test "executes a local call", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   helper()
                 end

                 def helper() do
                   3
                 end
               end
               """,
               ctx
             )
  end

  test "executes arithmetic", %{ctx: ctx} do
    assert 5 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   2 * 3 - 1
                 end
               end
               """,
               ctx
             )
  end

  test "executes a function with parameters", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   add(1, 2)
                 end

                 def add(a, b) do
                   a + b
                 end
               end
               """,
               ctx
             )
  end

  test "executes inlined scalar calls in arithmetic", %{ctx: ctx} do
    assert 6 ==
             Batata.execute(
               """
               defmodule Math do
                 def add(a, b) do
                   a + b
                 end

                 def main() do
                   add(1, 2) + 3
                 end
               end
               """,
               ctx
             )
  end

  test "executes nested scalar calls", %{ctx: ctx} do
    assert 10 ==
             Batata.execute(
               """
               defmodule Math do
                 def add(a, b) do
                   a + b
                 end

                 def main() do
                   add(add(1, 2), add(3, 4))
                 end
               end
               """,
               ctx
             )
  end

  test "executes tuple construction and predicates through the Zig runtime", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   is_tuple({1, 2})
                 end
               end
               """,
               ctx
             )
  end

  test "executes nested term construction through the Zig runtime", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   is_tuple({1, {2, 3}})
                 end
               end
               """,
               ctx
             )
  end

  test "executes list, map and binary construction through the Zig runtime", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   is_list([1, 2])
                   is_map(%{1 => 2})
                   is_binary(<<1, 2>>)
                 end
               end
               """,
               ctx
             )

    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   is_binary("ab")
                 end
               end
               """,
               ctx
             )
  end

  test "executes predicates over scalar integers and empty lists", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   is_integer(1)
                   is_list([])
                 end
               end
               """,
               ctx
             )
  end

  test "executes negative predicates through the Zig runtime", %{ctx: ctx} do
    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   is_list({1, 2})
                 end
               end
               """,
               ctx
             )
  end

  test "executes term construction with bindings through the Zig runtime", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = 1
                   is_tuple({a, 2})
                 end
               end
               """,
               ctx
             )
  end
end
