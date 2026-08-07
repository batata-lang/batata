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
end
