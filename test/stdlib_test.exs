defmodule Batata.StdlibTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Batata.Stdlib

  describe "domain registry" do
    test "classifies declared Kernel entries" do
      assert Stdlib.class({Kernel, :length, 1}) == :native_term
      assert Stdlib.class({Kernel, :hd, 1}) == :native_term
      assert Stdlib.class({Kernel, :elem, 2}) == :native_term
      assert Stdlib.class({Kernel, :map_size, 1}) == :native_term
      assert Stdlib.class({Kernel, :binary_part, 3}) == :native_term
      assert Stdlib.class({Kernel, :inspect, 1}) == :native_term
      assert Stdlib.class({Kernel, :inspect, 2}) == :native_term
      assert Stdlib.class({:erlang, :length, 1}) == :native_term
      assert Stdlib.class({IO, :iodata_to_binary, 1}) == :native_term
      assert Stdlib.class({:erlang, :iolist_to_binary, 1}) == :native_term
      assert Stdlib.class({:erlang, :binary_to_float, 1}) == :native_term
      assert Stdlib.class({:erlang, :float_to_binary, 2}) == :native_term
      assert Stdlib.class({:io_lib_format, :fwrite_g, 1}) == :native_term
      assert Stdlib.class({:erlang, :split_binary, 2}) == :native_term
      assert Stdlib.class({:erlang, :binary_part, 3}) == :native_term
      assert Stdlib.class({:binary, :at, 2}) == :native_term
      assert Stdlib.class({:binary, :copy, 1}) == :native_term
      assert Stdlib.class({:binary, :match, 2}) == :native_term
      assert Stdlib.class({Date, :to_iso8601, 1}) == :native_term
      assert Stdlib.class({DateTime, :to_iso8601, 1}) == :native_term
      assert Stdlib.class({Time, :to_iso8601, 1}) == :native_term
    end

    test "classifies declared domain modules" do
      assert Stdlib.class({List, :first, 1}) == :native_term
      assert Stdlib.class({List, :duplicate, 2}) == :native_term
      assert Stdlib.class({List, :flatten, 1}) == :native_term
      assert Stdlib.class({List, :wrap, 1}) == :native_term
      assert Stdlib.class({:lists, :any, 2}) == :native_term
      assert Stdlib.class({:lists, :duplicate, 2}) == :native_term
      assert Stdlib.class({:lists, :split, 2}) == :native_term
      assert Stdlib.class({Atom, :to_string, 1}) == :native_term
      assert Stdlib.class({String.Chars, :to_string, 1}) == :native_term
      assert Stdlib.class({Keyword, :get, 2}) == :native_term
      assert Stdlib.class({Keyword, :get, 3}) == :native_term
      assert Stdlib.class({Map, :size, 1}) == :native_term
      assert Stdlib.class({Map, :to_list, 1}) == :native_term
      assert Stdlib.class({:maps, :from_list, 1}) == :native_term
      assert Stdlib.class({Tuple, :size, 1}) == :native_term
      assert Stdlib.class({Tuple, :delete_at, 2}) == :unsupported
      assert Stdlib.class({:binary, :part, 3}) == :native_term
      assert Stdlib.class({String, :printable?, 1}) == :native_term
      assert Stdlib.class({String, :to_atom, 1}) == :native_term
      assert Stdlib.class({String, :duplicate, 2}) == :native_term
      assert Stdlib.class({Integer, :to_charlist, 1}) == :native_term
      assert Stdlib.class({:erlang, :integer_to_list, 1}) == :native_term
      assert Stdlib.class({:erlang, :integer_to_list, 2}) == nil
      assert Stdlib.class({Integer, :to_string, 2}) == :native_term
      assert Stdlib.class({Enum, :into, 2}) == :native_term
      assert Stdlib.class({Enum, :intersperse, 2}) == :native_term
      assert Stdlib.class({Enum, :count, 1}) == :native_term
      assert Stdlib.class({Enum, :map, 2}) == :beamer_callback
      assert Stdlib.class({Process, :link, 1}) == :native_term
      assert Stdlib.class({Process, :monitor, 1}) == :native_term
      assert Stdlib.class({Process, :flag, 2}) == :native_term
      assert Stdlib.class({Process, :get, 2}) == :native_term
      assert Stdlib.class({Process, :put, 2}) == :native_term
      assert Stdlib.class({:erlang, :get, 1}) == :native_term
      assert Stdlib.class({:erlang, :put, 2}) == :native_term
      assert Stdlib.class({:erlang, :exit, 2}) == :native_term
    end

    test "returns nil outside the declared surface" do
      assert Stdlib.class({Foo, :bar, 1}) == nil
      assert Stdlib.class({Kernel, :apply, 2}) == nil
      assert Stdlib.metadata({Foo, :bar, 1}) == nil
    end

    test "declares native calls which require an actor exception boundary" do
      assert Stdlib.may_raise?({Kernel, :to_string, 1})
      assert Stdlib.may_raise?({Kernel, :binary_part, 3})
      assert Stdlib.may_raise?({Atom, :to_string, 1})
      assert Stdlib.may_raise?({String.Chars, :to_string, 1})
      assert Stdlib.may_raise?({String, :printable?, 1})
      assert Stdlib.may_raise?({String, :to_atom, 1})
      assert Stdlib.may_raise?({List, :duplicate, 2})
      assert Stdlib.may_raise?({Date, :to_iso8601, 1})
      assert Stdlib.may_raise?({DateTime, :to_iso8601, 1})
      assert Stdlib.may_raise?({Integer, :to_charlist, 1})
      assert Stdlib.may_raise?({:erlang, :integer_to_list, 1})
      assert Stdlib.may_raise?({Integer, :to_string, 2})
      assert Stdlib.may_raise?({Enum, :into, 2})
      assert Stdlib.may_raise?({Enum, :intersperse, 2})
      assert Stdlib.may_raise?({Keyword, :get, 3})
      assert Stdlib.may_raise?({Time, :to_iso8601, 1})
      assert Stdlib.may_raise?({:erlang, :binary_to_float, 1})
      assert Stdlib.may_raise?({:erlang, :float_to_binary, 2})
      assert Stdlib.may_raise?({:io_lib_format, :fwrite_g, 1})
      assert Stdlib.may_raise?({:erlang, :split_binary, 2})
      assert Stdlib.may_raise?({:erlang, :binary_part, 3})
      assert Stdlib.may_raise?({:binary, :part, 3})
      assert Stdlib.may_raise?({:binary, :copy, 1})
      assert Stdlib.may_raise?({:maps, :from_list, 1})
      assert Stdlib.may_raise?({:lists, :any, 2})
      assert Stdlib.may_raise?({:lists, :duplicate, 2})
      assert Stdlib.may_raise?({:lists, :split, 2})
      refute Stdlib.may_raise?({String, :length, 1})
      refute Stdlib.may_raise?({Foo, :bar, 1})
    end

    test "classifies effects and resumable safe points" do
      assert Stdlib.metadata({Kernel, :byte_size, 1}) == %{
               purity: :pure,
               allocation: :none,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({:binary, :copy, 1}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({:maps, :from_list, 1}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :per_element
             }

      assert Stdlib.metadata({:lists, :split, 2}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :per_element
             }

      assert Stdlib.metadata({Enum, :reduce, 3}) == %{
               purity: :pure,
               allocation: :none,
               preemption: :resumable,
               reductions: :per_element
             }

      assert Stdlib.metadata({Keyword, :get, 3}) == %{
               purity: :pure,
               allocation: :none,
               preemption: :resumable,
               reductions: :per_element
             }

      assert Stdlib.metadata({:lists, :any, 2}) == %{
               purity: :pure,
               allocation: :none,
               preemption: :resumable,
               reductions: :per_element
             }

      assert Stdlib.metadata({File, :read!, 1}) == %{
               purity: :impure,
               allocation: :may_allocate,
               preemption: :blocking,
               reductions: :external
             }

      assert Stdlib.metadata({Date, :to_iso8601, 1}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({DateTime, :to_iso8601, 1}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({Time, :to_iso8601, 1}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({Integer, :to_charlist, 1}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({:erlang, :integer_to_list, 1}) ==
               Stdlib.metadata({Integer, :to_charlist, 1})

      assert Stdlib.metadata({Integer, :to_string, 2}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({List, :duplicate, 2}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :per_element
             }

      assert Stdlib.metadata({Enum, :into, 2}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :per_element
             }

      assert Stdlib.metadata({Enum, :intersperse, 2}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :per_element
             }

      assert Stdlib.metadata({Atom, :to_string, 1}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({String, :to_atom, 1}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :constant
             }

      assert Stdlib.metadata({:erlang, :split_binary, 2}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :per_element
             }

      assert Stdlib.metadata({Kernel, :binary_part, 3}) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :per_element
             }

      assert Enum.all?(Stdlib.classes(), fn {mfa, _class} -> Stdlib.metadata(mfa) != nil end)
    end
  end

  describe "execution" do
    test "extracts binary parts through all Kernel and Erlang aliases", %{ctx: ctx} do
      source = """
      defmodule NativeBinaryPart do
        def part(binary, start, length), do: binary_part(binary, start, length)

        def main() do
          binary = "Jason"

          {
            part(binary, 0, 2),
            part(binary, 4, -2),
            Kernel.binary_part(binary, 5, 0),
            :erlang.binary_part(binary, 1, 3),
            :binary.part(binary, 3, 2)
          }
        end
      end
      """

      expected = source |> Kernel.<>("\nNativeBinaryPart.main()") |> Code.eval_string() |> elem(0)
      assert Batata.execute(source, ctx) == expected

      ir = source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)
      refute ir =~ "__batata_fn_62696e6172795f70617274_3"
      assert ir =~ "ex.binary_part"
    end

    test "extracts binary parts with arithmetically updated offsets", %{ctx: ctx} do
      source = """
      defmodule DynamicBinaryPart do
        def part(binary, start, length), do: binary_part(binary, start, length)

        def main() do
          offset = 1 + 1
          length = offset + 1
          part("snowman", offset, length)
        end
      end
      """

      assert Batata.execute(source, ctx) == "owm"
    end

    test "raises for invalid binary part types and bounds", %{ctx: ctx} do
      for expression <- [
            ~s|binary_part("abc", -1, 1)|,
            ~s|binary_part("abc", 2, 2)|,
            ~s|binary_part("abc", 0, -1)|,
            ~s|binary_part(:not_binary, 0, 0)|,
            ~s|binary_part("abc", :not_integer, 1)|,
            ~s|binary_part("abc", 0, :not_integer)|
          ] do
        source = """
        defmodule InvalidBinaryPart do
          def main(), do: #{expression}
        end
        """

        assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
      end
    end

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
      assert 2 == execute("Kernel.rem(17, 5)", ctx)
      assert -2 == execute("Kernel.rem(-17, 5)", ctx)
      assert 3 == execute("Kernel.div(17, 5)", ctx)
      assert -3 == execute("Kernel.div(-17, 5)", ctx)
      assert 17 == execute("Kernel.max(17, 5)", ctx)
      assert -5 == execute("Kernel.max(-17, -5)", ctx)
      assert 5 == execute("Kernel.max(5, 5)", ctx)
      assert 5 == execute("Kernel.min(17, 5)", ctx)
      assert 3 == execute("Kernel.min(-17, -5) + 20", ctx)
      assert 5 == execute("Kernel.min(5, 5)", ctx)
      assert 17 == execute("Kernel.abs(-17)", ctx)
      assert 17 == execute("Kernel.abs(17)", ctx)
      assert 0 == execute("Kernel.abs(0)", ctx)

      assert 9_223_372_036_854_775_807 ==
               execute("Kernel.max(-9_223_372_036_854_775_808, 9_223_372_036_854_775_807)", ctx)

      assert -9_223_372_036_854_775_808 ==
               execute("Kernel.min(-9_223_372_036_854_775_808, 9_223_372_036_854_775_807)", ctx)

      assert 9_223_372_036_854_775_807 ==
               execute("Kernel.abs(-9_223_372_036_854_775_807)", ctx)

      assert_raise Batata.Lift.Error, fn ->
        Batata.compile(
          """
          defmodule GenericMax do
            def main(), do: Kernel.max(self(), self())
          end
          """,
          ctx
        )
      end

      for expression <- ["Kernel.min(self(), self())", "Kernel.abs(self())"] do
        assert_raise Batata.Lift.Error, fn ->
          Batata.compile(
            """
            defmodule GenericScalarRounding do
              def main(), do: #{expression}
            end
            """,
            ctx
          )
        end
      end
    end

    test "copies binaries through direct and captured :binary.copy/1 calls", %{ctx: ctx} do
      source = """
      defmodule BinaryCopy do
        def main() do
          copy = &:binary.copy/1
          {:binary.copy(<<>>), :binary.copy(<<65, 0, 255>>), copy.("Jason")}
        end
      end
      """

      expected = source |> Kernel.<>("\nBinaryCopy.main()") |> Code.eval_string() |> elem(0)
      assert Batata.execute(source, ctx) == expected
    end

    test "raises ArgumentError when :binary.copy/1 receives a non-binary", %{ctx: ctx} do
      source = """
      defmodule InvalidBinaryCopy do
        def main(), do: :binary.copy(:not_a_binary)
      end
      """

      assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
    end

    test "builds maps from proper pair lists with last duplicate winning", %{ctx: ctx} do
      source = """
      defmodule MapsFromList do
        def main() do
          from_list = &:maps.from_list/1
          {:maps.from_list([]), from_list.([{:a, 1}, {:b, 2}, {:a, 3}])}
        end
      end
      """

      expected = source |> Kernel.<>("\nMapsFromList.main()") |> Code.eval_string() |> elem(0)
      assert Batata.execute(source, ctx) == expected
    end

    test "raises ArgumentError for malformed :maps.from_list/1 inputs", %{ctx: ctx} do
      for input <- [
            ":not_a_list",
            "%{already: :a_map}",
            "[{:ok, 1}, :invalid]",
            "[{:ok, 1} | :improper]"
          ] do
        source = """
        defmodule InvalidMapsFromList do
          def main(), do: :maps.from_list(#{input})
        end
        """

        assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
      end
    end

    test "matches List.flatten/1 for nested proper lists", %{ctx: ctx} do
      expressions = [
        "List.flatten([1, [2, []], 3])",
        ~S|List.flatten([<<1, 2>>, [3], {:ok, 4}])|,
        "List.flatten([foo: [bar: 1]])"
      ]

      Enum.each(expressions, fn expression ->
        {expected, _binding} = Code.eval_string(expression)
        assert expected == execute(expression, ctx), expression
      end)
    end

    test "reads term sizes and elements", %{ctx: ctx} do
      assert 2 == execute("tuple_size({10, 20})", ctx)
      # A dynamic term returned as the scalar root exposes its tagged word;
      # embedding the values below verifies the zero-based term semantics.
      assert 80 == execute("elem({10, 20}, 0)", ctx)
      assert 160 == execute("elem({10, 20}, 1)", ctx)
      assert {10, 20} == execute("{elem({10, 20}, 0), elem({10, 20}, 1)}", ctx)
      assert 3 == execute("byte_size(<<1, 2, 3>>)", ctx)
      assert 1 == execute("map_size(%{1 => 2})", ctx)
      assert 2 == execute("Map.size(%{1 => 2, 3 => 4})", ctx)
      assert [{1, 2}, {3, 4}] == execute("Map.to_list(%{1 => 2, 3 => 4})", ctx)
      assert 2 == execute("Tuple.size({1, 2})", ctx)
      assert 3 == execute("Enum.count([1, 2, 3])", ctx)
      assert 2 == execute("Enum.count({1, 2})", ctx)
      assert 2 == execute("Enum.count(%{1 => 2, 3 => 4})", ctx)
      assert 4 == execute("Enum.count(<<1, 2, 3, 4>>)", ctx)
    end

    test "boxes static Map.put keys and values with BEAM semantics", %{ctx: ctx} do
      expression = "Map.put(%{8 => {8, <<23>>}}, 64, {64, <<63>>})"
      {expected, _binding} = Code.eval_string(expression)
      assert execute(expression, ctx) == expected
    end

    test "executes recognized Enum.map/2 and Enum.reduce/3 patterns", %{ctx: ctx} do
      assert 3 == execute("Enum.count(Enum.map([1, 2, 3], fn x -> x end))", ctx)

      assert [{2, 1}, {4, 3}] ==
               execute(
                 "Enum.map([{1, 2}, {3, 4}], fn {left, right} -> {right, left} end)",
                 ctx
               )

      assert [2, 1, 4, 3] ==
               execute(
                 "Enum.flat_map([{1, 2}, {3, 4}], fn {left, right} -> [right, left] end)",
                 ctx
               )

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
      assert 25 == execute("Enum.reduce([2, 2], 100, fn x, a -> div(a, x) end)", ctx)
      assert 10 == execute("Enum.reduce({2, 5}, 100, fn x, a -> div(a, x) end)", ctx)
      assert 1 == execute("Enum.reduce([3, 5], 100, fn x, a -> rem(a, x) end)", ctx)
      assert 3 == execute("Enum.reduce({7, 3}, 10, fn x, a -> rem(x, a) end)", ctx)

      assert 36 ==
               execute(
                 "c = 10\nEnum.reduce([1, 2, 3], 0, fn x, a -> a + x + c end)",
                 ctx
               )

      assert 36 ==
               execute(
                 "c = 10\nEnum.reduce({1, 2, 3}, 0, fn x, a -> x + a + c end)",
                 ctx
               )

      assert 13 ==
               execute(
                 "c = 5\nEnum.reduce(<<1, 2>>, 0, fn x, a -> a + x + c end)",
                 ctx
               )

      assert 23 ==
               execute(
                 "Enum.reduce({1, 2}, 0, fn x, a -> a + x + 10 end)",
                 ctx
               )

      assert 30 ==
               execute(
                 "c = 10\nEnum.reduce([1, 2], 0, fn x, a -> a + x * c end)",
                 ctx
               )

      assert 27 ==
               execute(
                 "c = 3\nEnum.reduce({4, 5}, 0, fn x, a -> x * c + a end)",
                 ctx
               )

      assert 3 == execute("Enum.count(1..3)", ctx)
      assert 6 == execute("Enum.reduce(1..3, 0, fn x, a -> x + a end)", ctx)
      assert 6 == execute("Enum.reduce(3..1, 0, fn x, a -> x + a end)", ctx)
      assert 6 == execute("Enum.reduce(1..3, 1, fn x, a -> x * a end)", ctx)

      assert 3 == execute("Enum.count(Enum.to_list([1, 2, 3]))", ctx)
      assert 3 == execute("Enum.count(Enum.to_list({1, 2, 3}))", ctx)
      assert 2 == execute("Enum.count(Enum.to_list(%{1 => 2, 3 => 4}))", ctx)
      assert 2 == execute("Enum.count(Enum.to_list(<<1, 2>>))", ctx)
      assert 3 == execute("Enum.count(Enum.to_list(1..3))", ctx)

      assert 12 ==
               execute(
                 "Enum.reduce(Enum.map([1, 2, 3], fn x -> x * 2 end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 12 ==
               execute(
                 "Enum.reduce(Enum.map({1, 2, 3}, fn x -> x * 2 end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 3 ==
               execute(
                 "Enum.reduce(Enum.map(<<3, 4>>, fn x -> x - 2 end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 2 ==
               execute(
                 "Enum.reduce([1, 2, 3], 0, fn x, a -> a + div(x, 2) end)",
                 ctx
               )

      assert 2 ==
               execute(
                 "Enum.reduce({1, 2, 3}, 0, fn x, a -> a + div(x, 2) end)",
                 ctx
               )

      assert 2 ==
               execute(
                 "Enum.reduce(<<1, 2, 3>>, 0, fn x, a -> a + rem(x, 2) end)",
                 ctx
               )

      assert 1 ==
               execute(
                 "Enum.reduce([1, 2, 3], 0, fn x, a -> a + (x > 2) end)",
                 ctx
               )

      assert 3 == execute("Enum.count(MapSet.new([1, 2, 2, 3]))", ctx)
      assert 6 == execute("Enum.reduce(MapSet.new([1, 2, 3]), 0, fn x, a -> x + a end)", ctx)
      assert 1 == execute("MapSet.member?(MapSet.new([1, 2, 3]), 2)", ctx)
      assert 0 == execute("MapSet.member?(MapSet.new([1, 2, 3]), 9)", ctx)
      assert 3 == execute("Enum.count(MapSet.put(MapSet.new([1, 2]), 3))", ctx)
      assert 2 == execute("Enum.count(MapSet.put(MapSet.new([1, 2]), 1))", ctx)
      assert 2 == execute("Enum.count(HashSet.new([1, 2, 2]))", ctx)

      assert 12 ==
               execute(
                 "Enum.reduce(Stream.map([1, 2, 3], fn x -> x * 2 end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 6 ==
               execute(
                 "Enum.reduce(Stream.filter([1, 2, 3, 4], fn x -> rem(x, 2) == 0 end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 70 ==
               execute(
                 "Enum.reduce(Stream.map(Stream.filter([1, 2, 3, 4], fn x -> x > 2 end), fn x -> x * 10 end), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 3 ==
               execute(
                 "Enum.reduce(Stream.take([1, 2, 3, 4], 2), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 0 == execute("Enum.count(Stream.take([1, 2, 3], 0))", ctx)

      assert 9 ==
               execute(
                 "Enum.reduce(Stream.drop([1, 2, 3, 4], 1), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 0 == execute("Enum.count(Stream.drop([1, 2, 3], 9))", ctx)

      assert 4 ==
               execute(
                 "Enum.reduce(Stream.take(Stream.filter([1, 2, 3, 4, 5], fn x -> rem(x, 2) == 1 end), 2), 0, fn x, a -> x + a end)",
                 ctx
               )

      assert 16 ==
               execute(
                 "Enum.reduce(<<1, 2, 3>>, 1, fn x, a -> a * x + 1 end)",
                 ctx
               )

      assert 55 ==
               execute(
                 "Enum.reduce({2, 3}, 10, fn x, a -> a * x - x + 1 end)",
                 ctx
               )

      assert 3 ==
               execute(
                 "Enum.count(Date.new(2024, 1, 1)..Date.new(2024, 1, 3))",
                 ctx
               )

      assert 3 ==
               execute(
                 "Enum.count(Enum.to_list(Date.new(2024, 1, 1)..Date.new(2024, 1, 3)))",
                 ctx
               )

      assert 366 == execute("Date.new(2024, 2, 29) - Date.new(2023, 2, 28)", ctx)
    end

    test "executes the Enumerable.List.reduce/3 callback contract", %{ctx: ctx} do
      sum_reducer = fn item, acc -> {:cont, item + acc} end
      reverse_reducer = fn item, acc -> {:cont, [item | acc]} end

      assert Enumerable.List.reduce([1, 2, 3], {:cont, 0}, sum_reducer) ==
               execute(
                 "Enumerable.List.reduce([1, 2, 3], {:cont, 0}, fn item, acc -> " <>
                   "{:cont, item + acc} end)",
                 ctx
               )

      assert Enumerable.List.reduce([1, 2, 3], {:halt, 7}, sum_reducer) ==
               execute(
                 "Enumerable.List.reduce([1, 2, 3], {:halt, 7}, fn item, acc -> " <>
                   "{:cont, item + acc} end)",
                 ctx
               )

      assert Enumerable.List.reduce([1, 2, 3], {:cont, []}, reverse_reducer) ==
               execute(
                 "Enumerable.List.reduce([1, 2, 3], {:cont, []}, fn item, acc -> " <>
                   "{:cont, [item | acc]} end)",
                 ctx
               )

      {:suspended, beam_acc, beam_continuation} =
        Enumerable.List.reduce([1, 2, 3], {:suspend, 0}, sum_reducer)

      beam_resumed = beam_continuation.({:cont, beam_acc})

      assert beam_resumed ==
               execute(
                 """
                 reducer = fn item, acc -> {:cont, item + acc} end
                 {:suspended, acc, continuation} =
                   Enumerable.List.reduce([1, 2, 3], {:suspend, 0}, reducer)
                 continuation.({:cont, acc})
                 """,
                 ctx
               )

      suspending_reducer = fn item, acc ->
        if item == 3, do: {:suspend, item + acc}, else: {:cont, item + acc}
      end

      {:suspended, beam_acc, beam_continuation} =
        Enumerable.List.reduce([1, 2, 3], {:cont, 0}, suspending_reducer)

      beam_resumed = beam_continuation.({:cont, beam_acc})

      assert beam_resumed ==
               execute(
                 """
                 reducer = fn item, acc ->
                   if item == 3, do: {:suspend, item + acc}, else: {:cont, item + acc}
                 end

                 {:suspended, acc, continuation} =
                   Enumerable.List.reduce([1, 2, 3], {:cont, 0}, reducer)

                 continuation.({:cont, acc})
                 """,
                 ctx
               )

      assert_raise CaseClauseError, fn ->
        execute(
          "Enumerable.List.reduce([1], {:cont, 0}, fn _item, _acc -> :bad end)",
          ctx
        )
      end
    end

    test "rejects non-literal Date.new explicitly", %{ctx: ctx} do
      error =
        assert_raise Batata.Lift.Error, fn ->
          execute(
            "y = 2024\nEnum.count(Date.new(y, 1, 1)..Date.new(2024, 1, 3))",
            ctx
          )
        end

      assert error.message =~ "Date.new requires integer literal"
    end

    test "reduction budget yields and resumes loops with consistent results", %{ctx: ctx} do
      source = """
      defmodule M do
        def main() do
          Enum.reduce([1, 2, 3, 4, 5], 0, fn x, a -> x + a end)
        end
      end
      """

      assert 15 == Batata.execute(source, ctx)
      # Budget 2: the loop yields/resumes (single-actor immediate resume),
      # so the result stays consistent across slices.
      assert 15 == Batata.execute(source, ctx, reduction_budget: 2)
      assert 15 == Batata.execute(source, ctx, reduction_budget: 10)
    end

    @tag :tmp_dir
    test "reads files via File.read!/File.stream!", %{ctx: ctx, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "lines.txt")
      File.write!(path, "alpha\nbeta\ngamma\n")

      assert 17 == execute("byte_size(File.read!(#{inspect(path)}))", ctx)
      assert 4 == execute("Enum.count(File.stream!(#{inspect(path)}))", ctx)

      assert 0 == execute("byte_size(File.read!(\"/definitely/missing/file\"))", ctx)
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

    test "executes String length, printable, and integer conversions", %{ctx: ctx} do
      assert 3 == execute("String.length(\"abc\")", ctx)
      assert 3 == execute("String.length(\"aé中\")", ctx)
      assert true == execute("String.printable?(\"\")", ctx)
      assert true == execute("String.printable?(\" ~\\a\\b\\t\\n\\v\\f\\r\\e\\d\")", ctx)
      assert false == execute("String.printable?(<<0>>)", ctx)
      assert false == execute("String.printable?(<<0xC2, 0x80>>)", ctx)
      assert true == execute("String.printable?(<<0xC2, 0xA0>>)", ctx)
      assert true == execute("String.printable?(<<0xED, 0x9F, 0xBF>>)", ctx)
      assert true == execute("String.printable?(<<0xEE, 0x80, 0x80>>)", ctx)
      assert true == execute("String.printable?(<<0xEF, 0xBF, 0xBD>>)", ctx)
      assert true == execute("String.printable?(<<0xF0, 0x90, 0x80, 0x80>>)", ctx)
      assert true == execute("String.printable?(<<0xF4, 0x8F, 0xBF, 0xBF>>)", ctx)
      assert false == execute("String.printable?(<<0xFF>>)", ctx)
      assert false == execute("String.printable?(<<0xC0, 0xAF>>)", ctx)
      assert false == execute("String.printable?(<<0xE2, 0x82>>)", ctx)
      assert false == execute("String.printable?(<<0xED, 0xA0, 0x80>>)", ctx)
      assert false == execute("String.printable?(<<0xF4, 0x90, 0x80, 0x80>>)", ctx)
      assert 42 == execute("String.to_integer(\"42\")", ctx)
      assert -7 == execute("String.to_integer(\"-7\")", ctx)
      assert 42 == execute("String.to_integer(Integer.to_string(42))", ctx)
    end

    test "matches Integer.to_charlist/1 across the tagged integer domain", %{ctx: ctx} do
      expressions = [
        "Integer.to_charlist(0)",
        "Integer.to_charlist(1)",
        "Integer.to_charlist(0 - 1)",
        "Integer.to_charlist(0 - 123)",
        "Integer.to_charlist(1_152_921_504_606_846_975)",
        "Integer.to_charlist(0 - 1_152_921_504_606_846_975 - 1)"
      ]

      Enum.each(expressions, fn expression ->
        {expected, _binding} = Code.eval_string(expression)
        assert expected == execute(expression, ctx), expression
      end)
    end

    test "aliases :erlang.integer_to_list/1 to the integer charlist lowering", %{ctx: ctx} do
      values = [0, 1, -1, -123, 1_152_921_504_606_846_975, -1_152_921_504_606_846_976]

      Enum.each(values, fn value ->
        erlang = execute(":erlang.integer_to_list(#{value})", ctx)
        elixir = execute("Integer.to_charlist(#{value})", ctx)

        assert erlang == :erlang.integer_to_list(value)
        assert erlang == elixir
      end)
    end

    test "lowers each integer charlist alias through one shared conversion path", %{ctx: ctx} do
      source = """
      defmodule IntegerCharlistAliases do
        def main(value), do: {Integer.to_charlist(value), :erlang.integer_to_list(value)}
      end
      """

      ir = source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)

      assert length(Regex.scan(~r/\"ex\.int_to_string\"/, ir)) == 2
      assert length(Regex.scan(~r/\"ex\.enumerable_to_list\"/, ir)) == 2
      refute ir =~ "__batata_fn_696e74656765725f746f5f6c697374_1"
    end

    test "matches Integer.to_string/2 across bases and the tagged integer domain", %{ctx: ctx} do
      expressions = [
        "Integer.to_string(0, 2)",
        "Integer.to_string(42, 2)",
        "Integer.to_string(42, 8)",
        "Integer.to_string(42, 10)",
        "Integer.to_string(42, 16)",
        "Integer.to_string(35, 36)",
        "Integer.to_string(0 - 255, 16)",
        "Integer.to_string(1_152_921_504_606_846_975, 36)",
        "Integer.to_string(0 - 1_152_921_504_606_846_975 - 1, 2)"
      ]

      Enum.each(expressions, fn expression ->
        {expected, _binding} = Code.eval_string(expression)
        assert expected == execute(expression, ctx)
      end)
    end

    test "supports a dynamic Integer.to_string/2 base", %{ctx: ctx} do
      source = """
      defmodule IntegerToStringBase do
        def render(value, base), do: Integer.to_string(value, base)
        def main(), do: {render(255, 16), render(35, 36), render(10, 2)}
      end
      """

      assert {"FF", "Z", "1010"} == Batata.execute(source, ctx)
    end

    test "matches Integer.to_string/2 argument errors", %{ctx: ctx} do
      first = "errors were found at the given arguments:\n\n  * 1st argument: not an integer\n"

      second =
        "errors were found at the given arguments:\n\n" <>
          "  * 2nd argument: not an integer in the range 2 through 36\n"

      both =
        "errors were found at the given arguments:\n\n" <>
          "  * 1st argument: not an integer\n" <>
          "  * 2nd argument: not an integer in the range 2 through 36\n"

      assert_raise ArgumentError, first, fn -> execute("Integer.to_string(1.5, 10)", ctx) end
      assert_raise ArgumentError, second, fn -> execute("Integer.to_string(1, 1)", ctx) end
      assert_raise ArgumentError, second, fn -> execute("Integer.to_string(1, 37)", ctx) end
      assert_raise ArgumentError, second, fn -> execute("Integer.to_string(1, :bad)", ctx) end
      assert_raise ArgumentError, both, fn -> execute("Integer.to_string(1.5, 1)", ctx) end
    end

    test "collects list and map enumerables into maps", %{ctx: ctx} do
      expressions = [
        "Enum.into([], %{a: 1})",
        "Enum.into([a: 2, b: 3], %{a: 1, c: 4})",
        "Enum.into([a: 2, a: 3], %{a: 1})",
        "Enum.into(%{a: 2, b: 3}, %{a: 1, c: 4})",
        "Enum.into([escape: :html_safe], %{escape: :json, maps: :naive})"
      ]

      Enum.each(expressions, fn expression ->
        {expected, _binding} = Code.eval_string(expression)
        assert expected == execute(expression, ctx)
      end)
    end

    test "rejects malformed bounded Enum.into/2 map collections", %{ctx: ctx} do
      assert_raise ArgumentError, "invalid Enum.into/2 map collection", fn ->
        execute("Enum.into([1], %{})", ctx)
      end

      assert_raise ArgumentError, "invalid Enum.into/2 map collection", fn ->
        execute("Enum.into([a: 1], [])", ctx)
      end
    end

    test "intersperses bounded enumerables while preserving iodata elements", %{ctx: ctx} do
      expressions = [
        "Enum.count(Enum.intersperse([], :separator))",
        "Enum.intersperse([1], :separator)",
        "Enum.intersperse([1, 2, 3], 0)",
        "Enum.intersperse(%{1 => 2, 3 => 4}, :separator)",
        ~S|IO.iodata_to_binary(Enum.intersperse([], ","))|,
        ~S|IO.iodata_to_binary(Enum.intersperse(["a", "b", "c"], ","))|
      ]

      Enum.each(expressions, fn expression ->
        {expected, _binding} = Code.eval_string(expression)
        assert expected == execute(expression, ctx)
      end)
    end

    test "rejects non-enumerable Enum.intersperse/2 inputs", %{ctx: ctx} do
      Enum.each(["1", "{1, 2}", "<<1, 2>>"], fn input ->
        assert_raise ArgumentError, "invalid Enum.intersperse/2 enumerable", fn ->
          execute("Enum.intersperse(#{input}, 0)", ctx)
        end
      end)
    end

    test "keeps bounded Integer.to_charlist/1 results stable under low budgets", %{ctx: ctx} do
      source = """
      defmodule IntegerToCharlistBudget do
        def main(), do: Integer.to_charlist(0 - 1_152_921_504_606_846_975 - 1)
      end
      """

      expected = Integer.to_charlist(-1_152_921_504_606_846_976)
      assert expected == Batata.execute(source, ctx, reduction_budget: 1)
      assert expected == Batata.execute(source, ctx, reduction_budget: 2)
    end

    test "matches Integer.to_charlist/1 argument errors", %{ctx: ctx} do
      message = "errors were found at the given arguments:\n\n  * 1st argument: not an integer\n"

      for expression <- [
            "Integer.to_charlist(1.5)",
            ":erlang.integer_to_list(1.5)",
            ~S|Integer.to_charlist("12")|,
            ~S|:erlang.integer_to_list("12")|,
            "Integer.to_charlist(:integer)"
          ] do
        assert_raise ArgumentError, message, fn -> execute(expression, ctx) end
      end
    end

    test "keeps :erlang.integer_to_list/2 outside the admitted surface", %{ctx: ctx} do
      error =
        assert_raise Batata.Lift.Error, fn ->
          execute(":erlang.integer_to_list(12, 16)", ctx)
        end

      assert error.message =~ "unsupported stdlib call: :erlang.integer_to_list/2"
    end

    test "matches the bounded Kernel.inspect surface", %{ctx: ctx} do
      expressions = [
        "inspect(0)",
        "inspect(65)",
        "inspect(0, base: :hex)",
        "inspect(10, base: :hex)",
        "inspect(255, base: :hex)",
        "inspect(0 - 255, base: :hex)",
        ~S|inspect("ab")|,
        ~S|inspect("a\"b")|,
        ~S|inspect("a\\b")|,
        ~S|inspect("a\nb")|,
        "inspect(<<0>>)",
        "inspect(<<255>>)",
        "inspect(<<1, 2>>)",
        "inspect(<<0xC3, 0xA9>>)",
        "inspect(:atom)",
        "inspect(nil)",
        "inspect(true)",
        "inspect(false)"
      ]

      Enum.each(expressions, fn expression ->
        {expected, _binding} = Code.eval_string(expression)
        assert expected == execute(expression, ctx), expression
      end)
    end

    test "rejects unsupported Kernel.inspect terms and options explicitly", %{ctx: ctx} do
      for expression <- ["inspect([1])", "inspect(%{a: 1})", "inspect(1.5)"] do
        error = assert_raise Batata.UnsupportedFeatureError, fn -> execute(expression, ctx) end
        assert error.reason == :unsupported_type
      end

      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("inspect(1, limit: 3)", ctx)
        end

      assert error.message =~ "supports only the literal option [base: :hex]"
    end

    test "matches String.printable?/1 non-binary FunctionClauseError", %{ctx: ctx} do
      expected =
        assert_raise FunctionClauseError, fn ->
          String.printable?(System.get_env("BATATA_NON_BINARY_ORACLE") || 1)
        end

      actual =
        assert_raise FunctionClauseError, fn ->
          execute("String.printable?(1)", ctx)
        end

      assert actual.module == expected.module
      assert actual.function == expected.function
      assert actual.arity == expected.arity
      assert actual.args == expected.args
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
          execute("Enum.reduce([1, 2, 3], 0, fn x, a -> a * x + z end)", ctx)
        end

      assert error.message =~ "requires BEAM callback interop"

      assert 15 == execute("Enum.reduce(1..3, 0, fn x, a -> a * x + x end)", ctx)

      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Enum.map([1, 2, 3], fn x -> is_integer(x) end)", ctx)
        end

      assert error.message =~ "requires BEAM callback interop"
    end

    test "rejects unrecognized BEAM-callback Enum calls explicitly", %{ctx: ctx} do
      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Enum.map([1, 2, 3], fn x -> is_integer(x) end)", ctx)
        end

      assert error.message =~ "requires BEAM callback interop"
    end

    test "rejects undeclared stdlib calls explicitly", %{ctx: ctx} do
      error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Foo.bar(1)", ctx)
        end

      assert error.message =~ "unsupported stdlib call: Foo.bar/1"

      nested_error =
        assert_raise Batata.Lift.Error, fn ->
          execute("Foo.Bar.baz(1)", ctx)
        end

      assert nested_error.message =~ "unsupported stdlib call: Foo.Bar.baz/1"
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
