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

  test "executes deep term equality on separately built terms", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   {1, 2} == {1, 2}
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
                   {1, 2} == {1, 3}
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
                   <<1, 2>> == <<1, 2>>
                 end
               end
               """,
               ctx
             )
  end

  test "executes nested deep term equality and inequality", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   {{1, 2}, 3} == {{1, 2}, 3}
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
                   {1, 2} != {1, 3}
                 end
               end
               """,
               ctx
             )
  end

  test "executes term equality in case guards", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {1, 2} do
                     x when x == {1, 2} -> 1
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
                     x when x == {1, 3} -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "executes a reduce-style accumulator scanner as a cursor loop", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def reduce(<<>>, acc) do
                   acc
                 end

                 def reduce(<<_h::8, t::binary>>, acc) do
                   reduce(t, acc + 1)
                 end

                 def reduce(_, acc) do
                   acc
                 end

                 def main() do
                   reduce(<<1, 2, 3>>, 0)
                 end
               end
               """,
               ctx
             )
  end

  test "executes multi-argument multi-clause dispatch", %{ctx: ctx} do
    assert 15 ==
             Batata.execute(
               """
               defmodule Math do
                 def pick(<<>>, acc) do
                   acc
                 end

                 def pick(<<_h::8, _t::binary>>, acc) do
                   acc + 10
                 end

                 def pick(_, acc) do
                   acc
                 end

                 def main() do
                   pick(<<1, 2>>, 5)
                 end
               end
               """,
               ctx
             )

    assert 5 ==
             Batata.execute(
               """
               defmodule Math do
                 def pick(<<>>, acc) do
                   acc
                 end

                 def pick(<<_h::8, _t::binary>>, acc) do
                   acc + 10
                 end

                 def pick(_, acc) do
                   acc
                 end

                 def main() do
                   pick(<<>>, 5)
                 end
               end
               """,
               ctx
             )
  end

  test "rejects multi-clause functions with non-variable trailing arguments", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/trailing arguments must be variables/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def f(1, 2) do
            1
          end

          def f(_, _) do
            0
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

  test "rejects multi-clause functions with inconsistent trailing argument names", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/same trailing argument names/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def f(1, a) do
            a
          end

          def f(_, b) do
            b
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

  test "executes bound anonymous functions via dot application", %{ctx: ctx} do
    assert 7 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   f = fn x -> x + 1 end
                   f.(2) + f.(3)
                 end
               end
               """,
               ctx
             )
  end

  test "executes directly applied anonymous functions", %{ctx: ctx} do
    assert 10 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   (fn x -> x * 2 end).(5)
                 end
               end
               """,
               ctx
             )

    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   (fn a, b -> a + b end).(1, 2)
                 end
               end
               """,
               ctx
             )
  end

  test "captures free variables in anonymous functions", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = 1
                   f = fn x -> x + a end
                   f.(2)
                 end
               end
               """,
               ctx
             )

    assert 6 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = 1
                   b = 2
                   f = fn x -> x + a + b end
                   f.(3)
                 end
               end
               """,
               ctx
             )
  end

  test "captured values are stable across applications", %{ctx: ctx} do
    assert 7 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = 1
                   f = fn x -> x + a end
                   f.(2) + f.(3)
                 end
               end
               """,
               ctx
             )
  end

  test "fn parameters shadow outer variables and are not captured", %{ctx: ctx} do
    assert 12 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = 1
                   f = fn a, x -> x + a end
                   f.(10, 2)
                 end
               end
               """,
               ctx
             )
  end

  test "passes anonymous functions as values and applies them dynamically", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def helper(f, x) do
                   f.(x)
                 end

                 def main() do
                   helper(fn a -> a + 1 end, 2)
                 end
               end
               """,
               ctx
             )

    assert 15 ==
             Batata.execute(
               """
               defmodule Math do
                 def apply(f, x) do
                   f.(x)
                 end

                 def main() do
                   a = 10
                   apply(fn y -> y + a end, 5)
                 end
               end
               """,
               ctx
             )
  end

  test "returns anonymous functions as values", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def make() do
                   fn x -> x + 1 end
                 end

                 def main() do
                   f = make()
                   f.(2)
                 end
               end
               """,
               ctx
             )
  end

  test "captures and applies functions from within closures", %{ctx: ctx} do
    assert 6 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   f = fn x -> x * 2 end
                   g = fn y -> f.(y) + 1 end
                   g.(2) + 1
                 end
               end
               """,
               ctx
             )
  end

  test "dispatches distinct function values correctly", %{ctx: ctx} do
    assert 30 ==
             Batata.execute(
               """
               defmodule Math do
                 def apply2(f, x) do
                   f.(x)
                 end

                 def main() do
                   apply2(fn a -> a * 10 end, 2) +
                     apply2(fn b -> b + 8 end, 2)
                 end
               end
               """,
               ctx
             )
  end

  test "receives messages sent to self", %{ctx: ctx} do
    assert 43 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, 42)

                   receive do
                     42 -> 43
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "receive matches integer messages in FIFO order", %{ctx: ctx} do
    assert 11 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, 1)
                   send(pid, 2)

                   receive do
                     x when is_integer(x) -> x + 10
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "receive falls through to the catch-all when empty", %{ctx: ctx} do
    assert 5 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   receive do
                     99 -> 1
                     _ -> 5
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "receive matches tuple messages and untags integer elements", %{ctx: ctx} do
    assert 2 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, {1, 2})

                   receive do
                     {a, b} when is_integer(a) -> a + 1
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "spawns a process that sends to the spawning process across preempted slices", %{
    ctx: ctx
  } do
    # With a reduction budget, the entry's cursor loop yields to the
    # scheduler; the spawned process runs during a suspended slice, sends a
    # message, and the resumed loop keeps the message in the mailbox.
    assert 57 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   me = self()
                   spawn(fn -> send(me, 42) end)
                   sum = Enum.reduce([1, 2, 3, 4, 5], 0, fn x, a -> x + a end)

                   receive do
                     42 -> sum + 42
                     _ -> 0
                   end
                 end
               end
               """,
               ctx,
               reduction_budget: 2
             )
  end

  test "runs spawned actors on the native worker pool", %{ctx: ctx} do
    assert 15 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   spawn(fn -> Enum.reduce([6, 7, 8, 9], 0, fn x, a -> x + a end) end)
                   Enum.reduce([1, 2, 3, 4, 5], 0, fn x, a -> x + a end)
                 end
               end
               """,
               ctx,
               workers: 2,
               reduction_budget: 2
             )
  end

  test "rejects invalid worker counts", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/workers must be an integer between 1 and 64/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def main(), do: 1
        end
        """,
        ctx,
        workers: 0
      )
    end
  end

  test "round-robins multiple spawned processes between preempted slices", %{ctx: ctx} do
    # Each spawned process gets its own slice while the entry is suspended;
    # both messages are delivered FIFO and observed by the entry on resume.
    assert 45 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   me = self()
                   spawn(fn -> send(me, 10) end)
                   spawn(fn -> send(me, 20) end)
                   sum = Enum.reduce([1, 2, 3, 4, 5], 0, fn x, a -> x + a end)

                   a = receive do
                     10 -> 10
                     _ -> 0
                   end

                   b = receive do
                     20 -> 20
                     _ -> 0
                   end

                   sum + a + b
                 end
               end
               """,
               ctx,
               reduction_budget: 2
             )
  end

  test "spawned processes run to completion under the scheduler driver", %{ctx: ctx} do
    # Without a budget the entry is not preempted, but the driver still
    # executes spawned processes after the entry completes.
    assert 15 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   me = self()
                   spawn(fn -> send(me, 42) end)
                   Enum.reduce([1, 2, 3, 4, 5], 0, fn x, a -> x + a end)
                 end
               end
               """,
               ctx
             )
  end

  test "selective receive skips non-matching messages and removes the first match", %{ctx: ctx} do
    # Without a catch-all clause, the receive scans the mailbox: non-matching
    # messages stay queued and the first match is removed (#35 slice 6).
    assert 43 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, 43)
                   send(pid, 42)

                   receive do
                     42 -> 43
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "selective receive scan resumes across preempted slices", %{ctx: ctx} do
    # The mailbox scan is a budgeted cursor loop: it yields mid-scan and
    # resumes from its saved cursor with a live mailbox-length check.
    assert 43 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, 1)
                   send(pid, 1)
                   send(pid, 42)

                   receive do
                     42 -> 43
                   end
                 end
               end
               """,
               ctx,
               reduction_budget: 2
             )
  end

  test "message arrival invalidates a suspended selective-receive scan (epoch wiring)", %{
    ctx: ctx
  } do
    # A spawned process delivers the matching message while the entry's scan
    # is suspended; the resumed scan observes it (the receive-type
    # continuation is invalidated, and the scan continues with the new
    # message visible through the live mailbox length).
    assert 43 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   me = self()
                   send(me, 1)
                   send(me, 1)
                   spawn(fn -> send(me, 42) end)

                   receive do
                     42 -> 43
                   end
                 end
               end
               """,
               ctx,
               reduction_budget: 2
             )
  end

  test "receive after times out immediately with timeout 0", %{ctx: ctx} do
    assert 2 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   receive do
                     42 -> 1
                   after
                     0 -> 2
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "receive after ignores non-matching messages then times out", %{ctx: ctx} do
    assert 2 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, 43)

                   receive do
                     42 -> 1
                   after
                     0 -> 2
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "receive after waits for a message from a spawned process (infinity)", %{ctx: ctx} do
    # The wait loop is preemptible: with a reduction budget it yields to the
    # spawned process, whose message is observed on the resumed scan.
    assert 43 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   me = self()
                   spawn(fn -> send(me, 42) end)

                   receive do
                     42 -> 43
                   after
                     :infinity -> 0
                   end
                 end
               end
               """,
               ctx,
               reduction_budget: 2
             )
  end

  test "receive after fires after a positive timeout with no message", %{ctx: ctx} do
    assert 2 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   receive do
                     42 -> 1
                   after
                     50 -> 2
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "fifo receive after times out on an empty mailbox", %{ctx: ctx} do
    assert 2 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   receive do
                     _ -> 1
                   after
                     0 -> 2
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "erlang.monotonic_time is non-decreasing", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = erlang.monotonic_time()
                   b = erlang.monotonic_time()
                   b >= a
                 end
               end
               """,
               ctx
             )
  end

  test "erlang.monotonic_time converts native units to the requested unit", %{ctx: ctx} do
    # `:millisecond` divides the native (nanosecond) clock by 1_000_000; the
    # two reads are taken back to back so the residual is well under 10ms.
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   ms = erlang.monotonic_time(:millisecond)
                   ns = erlang.monotonic_time()
                   delta = ns - ms * 1000000
                   delta * delta < 100000000000000
                 end
               end
               """,
               ctx
             )
  end

  test "erlang.unique_integer hands out increasing positive values", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = erlang.unique_integer()
                   b = erlang.unique_integer()
                   b > a
                 end
               end
               """,
               ctx
             )
  end

  test "erlang.unique_integer([:negative]) hands out decreasing values", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = erlang.unique_integer([:negative])
                   b = erlang.unique_integer([:negative])
                   b < a
                 end
               end
               """,
               ctx
             )
  end

  test "erlang.unique_integer([:monotonic, :positive]) is monotonic across calls", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   a = erlang.unique_integer([:monotonic, :positive])
                   b = erlang.unique_integer([:positive])
                   b > a
                 end
               end
               """,
               ctx
             )
  end

  test "nested receive matches a second message inside the first clause body", %{ctx: ctx} do
    # The outer selective scan removes the first match; the inner receive
    # scans the remaining mailbox independently.
    assert 4 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, {1, 2})
                   send(pid, {3, 4})

                   receive do
                     {a, _} when a == 1 ->
                       receive do
                         {3, b} when is_integer(b) -> b
                       end

                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "atom messages match in FIFO and selective receive", %{ctx: ctx} do
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, :x)

                   receive do
                     :x -> 1
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )

    assert 2 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, :a)
                   send(pid, :b)

                   receive do
                     :b -> 2
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "message priority: urgent-first receive with after 0 fallback", %{ctx: ctx} do
    # The first receive scans for :urgent with an immediate timeout; when a
    # match exists it wins over ordinary messages.
    assert 1 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, :normal)
                   send(pid, :urgent)

                   receive do
                     :urgent -> 1
                   after
                     0 ->
                       receive do
                         _ -> 2
                       end
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "message priority: fallback handles non-urgent messages", %{ctx: ctx} do
    assert 2 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, :normal)

                   receive do
                     :urgent -> 1
                   after
                     0 ->
                       receive do
                         _ -> 2
                       end
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "nested receive composes with message priority", %{ctx: ctx} do
    # Urgent message wins the outer scan; the inner receive then processes the
    # next ordinary message.
    assert 2 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   pid = self()
                   send(pid, :normal)
                   send(pid, :urgent)
                   send(pid, {1, 2})

                   receive do
                     :urgent ->
                       receive do
                         {1, a} when is_integer(a) -> a
                       end
                   after
                     0 -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "try catches a thrown value and untags it", %{ctx: ctx} do
    assert 43 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   try do
                     throw(42)
                   catch
                     x when is_integer(x) -> x + 1
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "try returns the body result when nothing is thrown", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   try do
                     1 + 2
                   catch
                     _ -> 0
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "throw unwinds through nested function calls", %{ctx: ctx} do
    assert 8 ==
             Batata.execute(
               """
               defmodule Math do
                 def helper() do
                   throw(7)
                 end

                 def main() do
                   try do
                     helper()
                   catch
                     x when is_integer(x) -> x + 1
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "try matches thrown tuples", %{ctx: ctx} do
    assert 10 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   try do
                     throw({1, 5})
                   catch
                     {1, n} when is_integer(n) -> n * 2
                   end
                 end
               end
               """,
               ctx
             )
  end
end
