defmodule Batata.BinaryPrefixPatternTest do
  use Batata.Case, async: true, group: :execution_engine

  test "matches literal binary prefixes with BEAM semantics", %{ctx: ctx} do
    source = """
    defmodule BinaryPrefixPatternOracle do
      def parse("+" <> rest), do: {:plus, rest}
      def parse("-" <> rest), do: {:minus, rest}
      def parse("é:" <> rest), do: {:unicode, rest}
      def parse(other), do: {:other, other}

      def parse_case(value) do
        case value do
          "ok:" <> rest -> {:ok, rest}
          _other -> :error
        end
      end

      def trailing(:tag, "value:" <> rest), do: {:tagged, rest}
      def trailing(_tag, other), do: {:other, other}

      def main() do
        {
          parse("+12"),
          parse("+"),
          parse("-9"),
          parse("é:snow"),
          parse(""),
          parse(:not_binary),
          parse_case("ok:done"),
          parse_case("no"),
          trailing(:tag, "value:42"),
          trailing(:other, "value:42")
        }
      end
    end
    """

    expected =
      source
      |> Kernel.<>("\nBinaryPrefixPatternOracle.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "rejects unsupported binary prefix pattern shapes", %{ctx: ctx} do
    for pattern <- [
          "prefix <> rest",
          ~S("" <> rest),
          ~S|"a" <> _|,
          ~S|"a" <> ("b" <> rest)|,
          "123 <> rest"
        ] do
      source = """
      defmodule UnsupportedBinaryPrefixPattern do
        def parse(#{pattern}), do: rest
        def parse(_other), do: :error
      end
      """

      assert_raise Batata.Lift.Error,
                   ~r/binary prefix patterns require a non-empty literal binary prefix and a variable suffix/,
                   fn -> Batata.compile(source, ctx) end
    end
  end
end
