defmodule Batata.StdlibTest do
  use Batata.Case, async: true

  alias Batata
  alias Batata.Stdlib

  describe "domain registry" do
    test "classifies declared Kernel entries" do
      assert Stdlib.class({Kernel, :length, 1}) == :native_term
      assert Stdlib.class({Kernel, :hd, 1}) == :native_term
      assert Stdlib.class({Kernel, :elem, 2}) == :native_term
      assert Stdlib.class({Kernel, :map_size, 1}) == :native_term
      assert Stdlib.class({:erlang, :length, 1}) == :native_term
    end

    test "classifies declared domain modules" do
      assert Stdlib.class({List, :first, 1}) == :native_term
      assert Stdlib.class({Map, :size, 1}) == :native_term
      assert Stdlib.class({Tuple, :size, 1}) == :native_term
      assert Stdlib.class({Tuple, :delete_at, 2}) == :unsupported
      assert Stdlib.class({Enum, :count, 1}) == :native_term
      assert Stdlib.class({Enum, :map, 2}) == :beamer_callback
    end

    test "returns nil outside the declared surface" do
      assert Stdlib.class({Foo, :bar, 1}) == nil
      assert Stdlib.class({Kernel, :apply, 2}) == nil
    end
  end

  describe "execution" do
    test "resolves auto-imported Kernel BIFs", %{ctx: ctx} do
      assert 3 == execute("length([1, 2, 3])", ctx)
      assert 8 == execute("hd([1, 2, 3])", ctx)
      assert 16 == execute("hd(tl([1, 2, 3]))", ctx)
      assert 1 == execute("is_integer(5)", ctx)
    end

    test "resolves module-qualified stdlib calls", %{ctx: ctx} do
      assert 3 == execute("Kernel.length([1, 2, 3])", ctx)
      assert 56 == execute("List.first([7, 8])", ctx)
      assert 1 == execute("Kernel.is_list([1])", ctx)
    end

    test "reads term sizes and elements", %{ctx: ctx} do
      assert 2 == execute("tuple_size({10, 20})", ctx)
      assert 80 == execute("elem({10, 20}, 1)", ctx)
      assert 160 == execute("elem({10, 20}, 2)", ctx)
      assert 3 == execute("byte_size(<<1, 2, 3>>)", ctx)
      assert 1 == execute("map_size(%{1 => 2})", ctx)
      assert 2 == execute("Map.size(%{1 => 2, 3 => 4})", ctx)
      assert 2 == execute("Tuple.size({1, 2})", ctx)
      assert 3 == execute("Enum.count([1, 2, 3])", ctx)
      assert 2 == execute("Enum.count({1, 2})", ctx)
      assert 2 == execute("Enum.count(%{1 => 2, 3 => 4})", ctx)
      assert 4 == execute("Enum.count(<<1, 2, 3, 4>>)", ctx)
    end

    test "executes recognized Enum.map/2 and Enum.reduce/3 patterns", %{ctx: ctx} do
      assert 3 == execute("Enum.count(Enum.map([1, 2, 3], fn x -> x end))", ctx)
      assert 6 == execute("Enum.reduce([1, 2, 3], 0, fn x, a -> x + a end)", ctx)
      assert 16 == execute("Enum.reduce([1, 2, 3], 10, fn x, a -> a + x end)", ctx)
      assert 42 == execute("Enum.reduce([1, 2, 3], 42, fn _x, a -> a end)", ctx)
      assert 6 == execute("Enum.reduce({1, 2, 3}, 0, fn x, a -> x + a end)", ctx)
      assert 6 == execute("Enum.reduce(<<1, 2, 3>>, 0, fn x, a -> x + a end)", ctx)

      assert 6 ==
               execute("Enum.reduce(%{1 => 2, 3 => 4}, 0, fn {_k, v}, acc -> acc + v end)", ctx)

      assert 16 ==
               execute(
                 "Enum.reduce(%{1 => 2, 3 => 4}, 10, fn {_k, v}, acc -> v + acc end)",
                 ctx
               )

      assert 4 ==
               execute(
                 "Enum.reduce(%{1 => 2, 3 => 4}, 0, fn {k, _v}, acc -> acc + k end)",
                 ctx
               )

      assert 14 ==
               execute(
                 "Enum.reduce(%{1 => 2, 3 => 4}, 10, fn {k, _v}, acc -> k + acc end)",
                 ctx
               )

      assert 10 ==
               execute(
                 "Enum.reduce(%{1 => 2, 3 => 4}, 0, fn {k, v}, acc -> acc + k + v end)",
                 ctx
               )

      assert 20 ==
               execute(
                 "Enum.reduce(%{1 => 2, 3 => 4}, 10, fn {k, v}, acc -> acc + k + v end)",
                 ctx
               )

      assert 10 ==
               execute(
                 "Enum.reduce(%{1 => 2, 3 => 4}, 0, fn {k, v}, acc -> v + k + acc end)",
                 ctx
               )

      assert 6 == execute("Enum.reduce([1, 2, 3], 1, fn x, a -> x * a end)", ctx)
      assert 12 == execute("Enum.reduce([1, 2, 3], 2, fn x, a -> a * x end)", ctx)
      assert 24 == execute("Enum.reduce({2, 3, 4}, 1, fn x, a -> x * a end)", ctx)
      assert 6 == execute("Enum.reduce(<<2, 3>>, 1, fn x, a -> x * a end)", ctx)
      assert 4 == execute("Enum.reduce([1, 2, 3], 10, fn x, a -> a - x end)", ctx)
      assert 4 == execute("Enum.reduce({1, 2, 3}, 10, fn x, a -> a - x end)", ctx)
      assert -8 == execute("Enum.reduce([1, 2, 3], 10, fn x, a -> x - a end)", ctx)
      assert 12 == execute("Enum.reduce([1, 2, 3], 0, fn x, a -> a + x * 2 end)", ctx)
      assert 16 == execute("Enum.reduce([1, 2, 3], 1, fn x, a -> a * x + 1 end)", ctx)
    end

    test "executes const and capture-add Enum.map/2 mappers", %{ctx: ctx} do
      assert 21 ==
               execute(
                 "Enum.reduce(Enum.map([1, 2, 3], fn _x -> 7 end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 36 ==
               execute(
                 "Enum.reduce(Enum.map([1, 2, 3], fn x -> x + 10 end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 36 ==
               execute(
                 "c = 10\nEnum.reduce(Enum.map([1, 2, 3], fn x -> x + c end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 36 ==
               execute(
                 "c = 10\nEnum.reduce(Enum.map([1, 2, 3], fn x -> c + x end), 0, fn x, a -> x + a end)",
                 ctx
               )
    end

    test "executes String.length/1 and String.to_integer/1", %{ctx: ctx} do
      assert 3 == execute("String.length(\"abc\")", ctx)
      assert 3 == execute("String.length(\"aé中\")", ctx)
      assert 42 == execute("String.to_integer(\"42\")", ctx)
      assert -7 == execute("String.to_integer(\"-7\")", ctx)
      assert 42 == execute("String.to_integer(Integer.to_string(42))", ctx)
    end

    test "executes Base16 encode/decode", %{ctx: ctx} do
      assert 4 == execute("byte_size(Base.encode16(<<1, 2>>))", ctx)
      assert 2 == execute("byte_size(Base.decode16(\"ABCD\"))", ctx)
      assert 2 == execute("byte_size(Base.decode16(Base.encode16(<<171, 205>>)))", ctx)
      assert 0 == execute("byte_size(Base.decode16(\"zz\"))", ctx)
    end

    test "rejects unrecognized Enum mapper/reducer shapes explicitly", %{ctx: ctx} do
      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Enum.reduce([1, 2, 3], 0, fn x, a -> x / a end)", ctx)
        end

      assert error.message =~ "requires BEAM callback interop"

      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Enum.reduce({1, 2, 3}, 0, fn x, a -> a + x * 2 end)", ctx)
        end

      assert error.message =~ "combination reducers require a list literal"

      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Enum.map([1, 2, 3], fn x -> x * 2 end)", ctx)
        end

      assert error.message =~ "requires BEAM callback interop"
    end

    test "rejects BEAM-callback stdlib calls explicitly", %{ctx: ctx} do
      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Enum.to_list([1, 2, 3])", ctx)
        end

      assert error.message =~ "requires BEAM callback interop"
    end

    test "rejects undeclared stdlib calls explicitly", %{ctx: ctx} do
      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Foo.bar(1)", ctx)
        end

      assert error.message =~ "unsupported stdlib call: Foo.bar/1"
    end

    test "rejects declared-but-unsupported stdlib calls explicitly", %{ctx: ctx} do
      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Tuple.delete_at({1, 2}, 1)", ctx)
        end

      assert error.message =~ "declared but not yet supported"
    end
  end

  defp execute(expr, ctx) do
    source = """
    defmodule Math do
      def main() do
        #{expr}
      end
    end
    """

    Batata.execute(source, ctx)
  end
end
