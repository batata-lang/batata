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

  test "executes case with integer patterns and catch-all", %{ctx: ctx} do
    assert 20 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case 2 do
                     1 -> 10
                     2 -> 20
                     _ -> 30
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes case falling through to the catch-all", %{ctx: ctx} do
    assert 30 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case 5 do
                     1 -> 10
                     _ -> 30
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes case with a guard narrowing the clause", %{ctx: ctx} do
    assert 20 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case 2 do
                     n when n > 1 -> 20
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )

    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case 0 do
                     n when n > 1 -> 20
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes case with a type-check guard through the Zig runtime", %{ctx: ctx} do
    assert 10 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case 1 do
                     n when is_integer(n) -> 10
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "rejects case without a final catch-all clause", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/catch-all/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def main() do
            case 2 do
              1 -> 10
            end
          end
        end
        """,
        ctx
      )
    end
  end

  test "executes tuple pattern matching through the Zig runtime", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     {a, b} -> is_integer(a)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes tuple pattern arity fall-through", %{ctx: ctx} do
    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     {a, b, c} -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes list cons pattern matching through the Zig runtime", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case [1, 2] do
                     [h | t] -> is_list(t)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes exact list pattern fall-through", %{ctx: ctx} do
    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case [1, 2] do
                     [] -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes literal element patterns through word equality", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     {1, b} -> is_integer(b)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )

    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     {2, b} -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes bound terms round-tripping through reconstruction", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     {a, b} -> is_tuple({a, b})
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes type-predicate guards on term patterns", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     {a, b} when is_integer(a) -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )

    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     {a, b} when is_list(a) -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes guards on literal element term patterns", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     {1, b} when is_integer(b) -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "rejects non-predicate guards on term patterns explicitly", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/unsupported guard on term pattern/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def main() do
            case {1, 2} do
              {a, b} when a > 1 -> 1
              _ -> 0
            end
          end
        end
        """,
        ctx
      )
    end
  end

  test "executes binary rest matching through the Zig runtime", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<1, 2>> do
                     <<h::8, t::binary>> -> is_binary(t)
                     _ -> 0
                   end
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
                   case <<1, 2>> do
                     <<h::8, t::binary>> -> is_integer(h)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes binary byte patterns with literal elements", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<1, 2>> do
                     <<1, b::8>> -> is_integer(b)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )

    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<1, 2>> do
                     <<2, b::8>> -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes exact binary length matching", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<1, 2>> do
                     <<a::8, b::8>> -> is_integer(b)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )

    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<1, 2>> do
                     <<a::8>> -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes binary rest length fall-through", %{ctx: ctx} do
    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<1>> do
                     <<a::8, b::8, t::binary>> -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "rejects unsupported binary segments explicitly", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/unsupported binary segment/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def main() do
            case <<1, 2>> do
              <<x::16>> -> 1
              _ -> 0
            end
          end
        end
        """,
        ctx
      )
    end

    assert_raise Batata.Lift.Error, ~r/rest segment must be the last/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def main() do
            case <<1, 2>> do
              <<a::8, t::binary, b::8>> -> 1
              _ -> 0
            end
          end
        end
        """,
        ctx
      )
    end
  end

  test "executes utf8 segment matching through the Zig runtime", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<0xC3, 0xA9>> do
                     <<c::utf8, t::binary>> -> is_integer(c)
                     _ -> 0
                   end
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
                   case <<0xC3, 0xA9, 0x41>> do
                     <<c::utf8, t::binary>> -> is_binary(t)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes exact utf8 length matching", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<0xC3, 0xA9>> do
                     <<c::utf8>> -> is_integer(c)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )

    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<0xC3>> do
                     <<c::utf8>> -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes mixed byte and utf8 segments", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<0x41, 0xC3, 0xA9>> do
                     <<a::8, c::utf8>> -> is_integer(a)
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "rejects invalid utf8 sequences with fall-through", %{ctx: ctx} do
    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case <<0xC0, 0x80>> do
                     <<c::utf8>> -> 1
                     _ -> 0
                   end
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

  @tag :multi_clause
  test "executes a recursive binary scanner via typed calls", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def count(<<>>) do
                   0
                 end

                 def count(<<_h::8, t::binary>>) do
                   1 + count(t)
                 end

                 def count(_) do
                   0
                 end

                 def main() do
                   count(<<1, 2, 3>>)
                 end
               end
               """,
               ctx
             )
  end

  @tag :multi_clause
  test "executes multi-clause function dispatch", %{ctx: ctx} do
    assert 30 ==
             Batata.execute(
               """
               defmodule Math do
                 def pick(<<>>) do
                   10
                 end

                 def pick(<<_h::8, _t::binary>>) do
                   20
                 end

                 def pick(_) do
                   0
                 end

                 def main() do
                   pick(<<>>) + pick(<<1>>)
                 end
               end
               """,
               ctx
             )
  end

  @tag :multi_clause
  test "rejects multi-clause functions without a final catch-all", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/catch-all/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def f(1) do
            1
          end

          def f(2) do
            2
          end

          def main() do
            f(1)
          end
        end
        """,
        ctx
      )
    end
  end

  @tag :multi_clause
  test "rejects multi-clause functions with multiple arguments", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/multiple arguments are unsupported/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def f(a, b) do
            a
          end

          def f(c, d) do
            c
          end

          def main() do
            f(1, 2)
          end
        end
        """,
        ctx
      )
    end
  end

  test "executes a cursor-loop scanner with a non-zero base and delta", %{ctx: ctx} do
    assert 14 ==
             Batata.execute(
               """
               defmodule Math do
                 def total(<<>>) do
                   10
                 end

                 def total(<<_h::8, t::binary>>) do
                   2 + total(t)
                 end

                 def total(_) do
                   0
                 end

                 def main() do
                   total(<<1, 2>>)
                 end
               end
               """,
               ctx
             )
  end

  test "executes a cursor-loop scanner with a negative delta", %{ctx: ctx} do
    assert -3 ==
             Batata.execute(
               """
               defmodule Math do
                 def sub(<<>>) do
                   0
                 end

                 def sub(<<_h::8, t::binary>>) do
                   sub(t) - 1
                 end

                 def sub(_) do
                   0
                 end

                 def main() do
                   sub(<<1, 2, 3>>)
                 end
               end
               """,
               ctx
             )
  end

  test "leaves non-scanner recursion as recursive calls", %{ctx: ctx} do
    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def double_count(<<>>) do
                   0
                 end

                 def double_count(<<_h::8, t::binary>>) do
                   double_count(t) * 2
                 end

                 def double_count(_) do
                   0
                 end

                 def main() do
                   double_count(<<1, 2>>)
                 end
               end
               """,
               ctx
             )
  end
end
