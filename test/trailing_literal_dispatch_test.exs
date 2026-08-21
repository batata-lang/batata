defmodule Batata.TrailingLiteralDispatchTest do
  use Batata.Case, async: true

  test "dispatches Jason-shaped module literals with BEAM semantics", %{ctx: ctx} do
    source = """
    defmodule TrailingModuleOracle do
      defp struct(value, _escape, _encode_map, Date), do: {:date, value}
      defp struct(value, _escape, _encode_map, Time), do: {:time, value}
      defp struct(value, _escape, _encode_map, NaiveDateTime), do: {:naive, value}
      defp struct(value, _escape, _encode_map, DateTime), do: {:datetime, value}
      defp struct(value, _escape, _encode_map, _module), do: {:other, value}

      defp raw(value, :known), do: {:known, value}
      defp raw(value, _kind), do: {:unknown, value}

      def main() do
        {
          struct(1, :escape, %{}, :"Elixir.Date"),
          struct(2, :escape, %{}, :"Elixir.Time"),
          struct(3, :escape, %{}, :"Elixir.NaiveDateTime"),
          struct(4, :escape, %{}, :"Elixir.DateTime"),
          struct(5, :escape, %{}, :"Elixir.Foreign"),
          raw(6, :known),
          raw(7, :other)
        }
      end
    end
    """

    expected =
      source |> Kernel.<>("\nTrailingModuleOracle.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "conjoins multiple trailing literals and preserves clause priority", %{ctx: ctx} do
    source = """
    defmodule TrailingLiteralConjunctionOracle do
      defp route(0, Date, Time), do: :exact
      defp route(_, Date, _time), do: :date
      defp route(_, _date, _time), do: :other

      def main() do
        {
          route(0, :"Elixir.Date", :"Elixir.Time"),
          route(1, :"Elixir.Date", :"Elixir.Time"),
          route(0, :"Elixir.Date", :"Elixir.Foreign"),
          route(0, :"Elixir.Foreign", :"Elixir.Time")
        }
      end
    end
    """

    expected =
      source
      |> Kernel.<>("\nTrailingLiteralConjunctionOracle.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "combines trailing literals with term-pattern dispatch", %{ctx: ctx} do
    source = """
    defmodule TrailingLiteralTermOracle do
      defp route(<<>>, Date), do: :empty_date
      defp route(<<_byte::8>>, Date), do: :byte_date
      defp route(_, Date), do: :date
      defp route(_, _module), do: :other

      def main() do
        {
          route(<<>>, :"Elixir.Date"),
          route(<<7>>, :"Elixir.Date"),
          route(<<7, 8>>, :"Elixir.Date"),
          route(<<>>, :"Elixir.Foreign")
        }
      end
    end
    """

    expected =
      source
      |> Kernel.<>("\nTrailingLiteralTermOracle.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "conjoins trailing literals with guards over trailing bindings", %{ctx: ctx} do
    source = """
    defmodule TrailingLiteralGuardOracle do
      defp guarded(value, kind, Date) when is_atom(kind), do: {:guarded, value}
      defp guarded(value, _kind, Date), do: {:date, value}
      defp guarded(value, _kind, _module), do: {:other, value}

      def main() do
        {
          guarded(1, :ok, :"Elixir.Date"),
          guarded(2, 0, :"Elixir.Date"),
          guarded(3, :ok, :"Elixir.Foreign")
        }
      end
    end
    """

    expected =
      source
      |> Kernel.<>("\nTrailingLiteralGuardOracle.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "matches and binds aliased trailing atom literals", %{ctx: ctx} do
    source = """
    defmodule TrailingLiteralAliasOracle do
      defp route(value, true = enabled), do: {:enabled, value, enabled}
      defp route(value, false = enabled), do: {:disabled, value, enabled}
      defp route(value, _enabled), do: {:other, value}

      def main(), do: {route(1, true), route(2, false), route(3, :unknown)}
    end
    """

    expected =
      source
      |> Kernel.<>("\nTrailingLiteralAliasOracle.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "preserves all arguments when no trailing literal clause matches", %{ctx: ctx} do
    source = """
    defmodule TrailingLiteralFailure do
      defp only(value, escape, map, Date), do: {:date, value, escape, map}
      defp only(value, escape, map, Time), do: {:time, value, escape, map}
      def main(), do: only(1, 2, 3, :"Elixir.Foreign")
    end
    """

    error = assert_raise FunctionClauseError, fn -> Batata.execute(source, ctx) end

    assert error.module == TrailingLiteralFailure
    assert error.function == :only
    assert error.arity == 4
    assert error.args == [1, 2, 3, :"Elixir.Foreign"]
  end

  test "rejects non-atom trailing literals", %{ctx: ctx} do
    for literal <- ["2", ~S("binary"), "%{}", "[]"] do
      assert_raise Batata.Lift.Error,
                   ~r/trailing arguments must be variables, wildcards, or compile-known atom literals/,
                   fn ->
                     Batata.execute(
                       """
                       defmodule InvalidTrailingLiteral do
                         defp pick(0, #{literal}), do: 1
                         defp pick(_, _), do: 0
                         def main(), do: pick(0, #{literal})
                       end
                       """,
                       ctx
                     )
                   end
    end
  end
end
