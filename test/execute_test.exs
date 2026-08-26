defmodule Batata.ExecuteTest do
  use Batata.Case, async: true

  alias Batata
  alias Batata.Memory.Plan

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

  test "materializes __MODULE__ inside a protocol implementation", %{ctx: ctx} do
    source = """
    defimpl NativeModuleMarker, for: Integer do
      def main(), do: __MODULE__
    end
    """

    assert Batata.execute(source, ctx) == NativeModuleMarker.Integer
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

  test "JIT lifecycle materializes a composite result on repeated executions", %{ctx: ctx} do
    source = """
    defmodule Composite do
      def main(), do: {1, [2, 3], %{7 => 42}, <<4, 5>>}
    end
    """

    expected = {1, [2, 3], %{7 => 42}, <<4, 5>>}
    assert Batata.execute(source, ctx) == expected
    assert Batata.execute(source, ctx) == expected
  end

  test "materializes boxed float terms without changing their bits", %{ctx: ctx} do
    for value <- [12.5, -0.0, :math.pow(2.0, 1023)] do
      source = """
      defmodule FloatLiteral do
        def main(), do: #{inspect(value)}
      end
      """

      assert <<Batata.execute(source, ctx)::float-64-native>> == <<value::float-64-native>>
    end
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

  test "raises CaseClauseError when case has no matching clause", %{ctx: ctx} do
    error =
      assert_raise CaseClauseError, fn ->
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

    assert error.term == 2
  end

  test "adapts a synthesized case fallback to term-valued branches", %{ctx: ctx} do
    source = """
    defmodule TermCaseFallback do
      def select(value) do
        case value do
          1 -> {:ok, :one}
          2 -> {:ok, :two}
        end
      end

      def main(), do: select(2)
    end
    """

    assert Batata.execute(source, ctx) == {:ok, :two}

    error =
      assert_raise CaseClauseError, fn ->
        Batata.execute(String.replace(source, "select(2)", "select(3)"), ctx)
      end

    assert error.term == 3
  end

  test "dispatches case clauses with atom literal patterns", %{ctx: ctx} do
    source = """
    defmodule AtomCaseDispatch do
      def choose(value) do
        case value do
          :json -> :escaped
          :unicode_safe -> :unicode
          nil -> :missing
          _ -> :other
        end
      end

      def main(), do: {choose(:json), choose(:unicode_safe), choose(nil), choose(:unknown)}
    end
    """

    expected = source |> Kernel.<>("\nAtomCaseDispatch.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "returns and invokes module-local function captures", %{ctx: ctx} do
    source = """
    defmodule LocalFunctionCapture do
      def choose(:json), do: &escape_json/1
      def choose(:unicode), do: &escape_unicode/1

      def escape_json(value), do: value + 1
      def escape_unicode(value), do: value + 2

      def main() do
        json = choose(:json)
        unicode = choose(:unicode)
        {json.(4), unicode.(4)}
      end
    end
    """

    expected =
      source |> Kernel.<>("\nLocalFunctionCapture.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "returns and invokes remote function captures", %{ctx: ctx} do
    source = """
    defmodule RemoteFunctionCapture do
      def choose(:atom_module), do: &:erlang.length/1
      def choose(:alias_module), do: &Kernel.length/1

      def main() do
        atom_length = choose(:atom_module)
        alias_length = choose(:alias_module)

        {atom_length.([:one]), alias_length.([:one, :two, :three])}
      end
    end
    """

    expected =
      source |> Kernel.<>("\nRemoteFunctionCapture.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "maps byte-aligned binary comprehensions in source order", %{ctx: ctx} do
    source = """
    defmodule BinaryComprehension do
      def main() do
        offset = 2
        for <<(<<byte>> <- <<1, 3, 5>>) >>, do: byte + offset
      end
    end
    """

    expected =
      source |> Kernel.<>("\nBinaryComprehension.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "normalizes local and remote pipeline stages", %{ctx: ctx} do
    source = """
    defmodule PipelineDispatch do
      def add(left, right), do: left + right
      def double(value), do: value * 2

      def main() do
        value =
          4
          |> add(3)
          |> double()

        length = [:first, :second] |> Kernel.length()
        {value, length}
      end
    end
    """

    expected = source |> Kernel.<>("\nPipelineDispatch.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "typed case failures bypass user catch frames", %{ctx: ctx} do
    error =
      assert_raise CaseClauseError, fn ->
        Batata.execute(
          """
          defmodule Math do
            def main() do
              try do
                case 2 do
                  1 -> 10
                end
              catch
                _ -> 99
              end
            end
          end
          """,
          ctx
        )
      end

    assert error.term == 2
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

  test "executes atom-keyed map subset patterns through the Zig runtime", %{ctx: ctx} do
    assert %{position: nil, extra: 1} ==
             Batata.execute(
               """
               defmodule AtomMap do
                 def main(), do: %{position: nil, extra: 1}
               end
               """,
               ctx
             )

    assert {1, 0, 0, 1} ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   {
                     case %{position: nil, extra: 1} do
                       %{position: position} -> is_atom(position)
                       _ -> 0
                     end,
                     case %{extra: 1} do
                       %{position: position} -> is_atom(position)
                       _ -> 0
                     end,
                     case 1 do
                       %{position: position} -> is_atom(position)
                       _ -> 0
                     end,
                     case %{position: nil, token: 7, extra: 1} do
                       %{position: position, token: _token} -> is_atom(position)
                       _ -> 0
                     end
                   }
                 end
               end
               """,
               ctx
             )
  end

  test "matches atom-keyed map patterns in function parameters", %{ctx: ctx} do
    source = fn argument ->
      """
      defmodule DecimalStyleError do
        def message(%{signal: signal, reason: reason}), do: {signal, reason}
        def main(), do: message(#{argument})
      end
      """
    end

    assert {:invalid_operation, :bad_number} ==
             Batata.execute(
               source.("%{signal: :invalid_operation, reason: :bad_number, extra: 1}"),
               ctx
             )

    for argument <- ["%{signal: :invalid_operation}", "1"] do
      error = assert_raise FunctionClauseError, fn -> Batata.execute(source.(argument), ctx) end
      assert error.module == DecimalStyleError
      assert error.function == :message
      assert error.arity == 1
    end
  end

  test "matches pinned atom and binary keys with BEAM semantics", %{ctx: ctx} do
    source = """
    defmodule PinnedMapKeyOracle do
      def classify(map, key) do
        case map do
          %{^key => :expected} -> {:exact, key}
          %{^key => value} -> {:value, value}
          _ -> :missing
        end
      end

      def nested(map, key) do
        case map do
          %{outer: %{^key => value}} -> {:nested, value}
          _ -> :missing
        end
      end

      def main() do
        {
          classify(%{known: :expected}, :known),
          classify(%{"binary" => :other}, "binary"),
          classify(%{"other" => :expected}, "binary"),
          nested(%{outer: %{"nested" => 4}}, "nested")
        }
      end
    end
    """

    expected =
      source |> Kernel.<>("\nPinnedMapKeyOracle.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "rejects an unbound pinned map key", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/pinned map key requires an outer binding: key/, fn ->
      Batata.execute(
        """
        defmodule UnboundPinnedMapKey do
          def main() do
            case %{known: 1} do
              %{^key => _} -> :match
              _ -> :missing
            end
          end
        end
        """,
        ctx
      )
    end

    assert_raise Batata.Lift.Error,
                 ~r/map patterns only support atom literal or pinned keys/,
                 fn ->
                   Batata.execute(
                     """
                     defmodule DynamicMapKeyExpression do
                       def main() do
                         case %{"a" => 1} do
                           %{String.downcase("A") => _} -> :match
                           _ -> :missing
                         end
                       end
                     end
                     """,
                     ctx
                   )
                 end
  end

  test "matches map value subpatterns and binds pattern aliases", %{ctx: ctx} do
    source = """
    defmodule DecimalPatternShape do
      def classify(%{coef: :NaN} = number), do: {:nan, number}
      def classify(%{sign: sign}), do: {:finite, sign}

      def main() do
        {
          classify(%{coef: :NaN, sign: 1}),
          classify(%{coef: 10, sign: 2}),
          case %{outer: %{status: :ok}, extra: 1} do
            %{outer: %{status: :ok}} = whole -> whole
            _ -> :miss
          end
        }
      end
    end
    """

    expected =
      source |> Kernel.<>("\nDecimalPatternShape.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "matches validated current-module struct patterns", %{ctx: ctx} do
    source = """
    defmodule DecimalStructPattern do
      defstruct sign: 1, coef: 0

      def classify(%__MODULE__{coef: :NaN} = number), do: {:nan, number}
      def classify(%__MODULE__{sign: sign}), do: {:finite, sign}
      def classify(_other), do: :other

      def struct?(%__MODULE__{}), do: true
      def struct?(_other), do: false

      def main() do
        {
          classify(%__MODULE__{coef: :NaN}),
          classify(%__MODULE__{sign: -1, coef: 10}),
          classify(%{__struct__: :"Elixir.Other", sign: 1, coef: 0}),
          struct?(%__MODULE__{}),
          struct?(%{sign: 1, coef: 0}),
          struct?(1)
        }
      end
    end
    """

    expected =
      source |> Kernel.<>("\nDecimalStructPattern.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "rejects unknown and unavailable struct pattern schemas", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/unknown struct pattern fields: \[:unknown\]/, fn ->
      Batata.compile(
        """
        defmodule UnknownStructPattern do
          defstruct [:value]
          def classify(%__MODULE__{unknown: value}), do: value
          def main(), do: classify(%__MODULE__{})
        end
        """,
        ctx
      )
    end

    assert_raise Batata.Lift.Error, ~r/requires the current-module schema/, fn ->
      Batata.compile(
        """
        defmodule UnavailableStructPattern do
          def classify(%Other.Struct{value: value}), do: value
          def main(), do: classify(%{value: 1})
        end
        """,
        ctx
      )
    end
  end

  test "executes exact map updates with BEAM evaluation order", %{ctx: ctx} do
    source = """
    defmodule ExactMapUpdate do
      def emit(parent, value) do
        send(parent, value)
      end

      def main() do
        parent = self()
        map = %{first: 0, second: 0, keep: 3}
        updated = %{map | first: emit(parent, 1), second: emit(parent, 2)}

        first = receive do value -> value end
        second = receive do value -> value end
        {updated, first, second}
      end
    end
    """

    expected = source |> Kernel.<>("\nExactMapUpdate.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx, reduction_budget: 2) == expected
  end

  test "reads struct and map fields with typed failures", %{ctx: ctx} do
    source = """
    defmodule StructFieldAccess do
      defstruct sign: 1, coef: 0

      def read(number), do: {number.sign, number.coef}
      def main(), do: {read(%__MODULE__{sign: -1, coef: 42}), read(%{sign: 1, coef: 7})}
    end
    """

    expected = source |> Kernel.<>("\nStructFieldAccess.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected

    key_error =
      assert_raise KeyError, fn ->
        Batata.execute(
          """
          defmodule MissingFieldAccess do
            def read(value), do: value.missing
            def main(), do: read(%{present: 1})
          end
          """,
          ctx
        )
      end

    assert key_error.key == :missing
    assert key_error.term == %{present: 1}

    bad_map_error =
      assert_raise BadMapError, fn ->
        Batata.execute(
          """
          defmodule InvalidFieldAccess do
            def read(value), do: value.missing
            def main(), do: read(1)
          end
          """,
          ctx
        )
      end

    assert bad_map_error.term == 1
  end

  test "raises typed errors for invalid exact map updates", %{ctx: ctx} do
    key_error =
      assert_raise KeyError, fn ->
        Batata.execute(
          """
          defmodule MissingMapUpdateKey do
            def main(), do: %{%{} | missing: 1}
          end
          """,
          ctx
        )
      end

    assert key_error.key == :missing
    assert key_error.term == %{}

    bad_map_error =
      assert_raise BadMapError, fn ->
        Batata.execute(
          """
          defmodule InvalidMapUpdateBase do
            def main(), do: %{1 | missing: 1}
          end
          """,
          ctx
        )
      end

    assert bad_map_error.term == 1
  end

  test "evaluates map update values before validating keys", %{ctx: ctx} do
    error =
      assert_raise CaseClauseError, fn ->
        Batata.execute(
          """
          defmodule MapUpdateValueOrder do
            def main() do
              %{%{} | missing: 1, later: (case 2 do 1 -> 2 end)}
            end
          end
          """,
          ctx
        )
      end

    assert error.term == 2
  end

  test "executes Kernel.to_string over its supported dynamic term domain", %{ctx: ctx} do
    assert {"123", "binary", "known"} ==
             Batata.execute(
               """
               defmodule NativeStringChars do
                 def main() do
                   {Kernel.to_string(123), Kernel.to_string("binary"), Kernel.to_string(:known)}
                 end
               end
               """,
               ctx
             )
  end

  test "raises a typed error for unsupported Kernel.to_string values", %{ctx: ctx} do
    error =
      assert_raise Batata.UnsupportedFeatureError, fn ->
        Batata.execute(
          """
          defmodule NativeStringChars do
            def main(), do: Kernel.to_string([1])
          end
          """,
          ctx
        )
      end

    assert error.reason == :unsupported_type
    assert error.value == [1]
  end

  test "executes the direct String.Chars callback over the supported scalar domain", %{ctx: ctx} do
    assert {"123", "binary", "known"} ==
             Batata.execute(
               """
               defmodule NativeStringCharsCallback do
                 def main() do
                   {String.Chars.to_string(123), String.Chars.to_string("binary"),
                    String.Chars.to_string(:known)}
                 end
               end
               """,
               ctx
             )
  end

  test "raises a typed error for unsupported direct String.Chars callback values", %{ctx: ctx} do
    error =
      assert_raise Batata.UnsupportedFeatureError, fn ->
        Batata.execute(
          """
          defmodule NativeStringCharsCallbackFailure do
            def main(), do: String.Chars.to_string([1])
          end
          """,
          ctx
        )
      end

    assert error.reason == :unsupported_type
    assert error.value == [1]
  end

  test "lowers binary interpolation through Kernel.to_string", %{ctx: ctx} do
    assert {"value=42!", "left/right", "atom=known"} ==
             Batata.execute(
               """
               defmodule NativeInterpolation do
                 def main() do
                   {"value=#{42}!", "#{"left"}/#{"right"}", "atom=#{:known}"}
                 end
               end
               """,
               ctx
             )
  end

  test "reads bytes within the supported :binary.at domain", %{ctx: ctx} do
    assert {1, 2, 3} ==
             Batata.execute(
               """
               defmodule NativeBinaryAt do
                 def main() do
                   binary = <<1, 2, 3>>
                   {:binary.at(binary, 0), :binary.at(binary, 1), :binary.at(binary, 2)}
                 end
               end
               """,
               ctx
             )
  end

  test "uses :binary.at results in integer dispatch and arithmetic", %{ctx: ctx} do
    assert {2, 93} ==
             Batata.execute(
               """
               defmodule NativeBinaryAtScalar do
                 def main() do
                   binary = <<34, 92, 118>>

                   kind =
                     case :binary.at(binary, 0) do
                       92 -> 1
                       34 -> 2
                       _ -> 0
                     end

                   {kind, :binary.at(binary, 1) + 1}
                 end
               end
               """,
               ctx
             )
  end

  test "matches compile-known byte patterns in binaries", %{ctx: ctx} do
    source = """
    defmodule NativeBinaryMatch do
      def main() do
        {
          :binary.match(<<10, 65, 30>>, ["A", "("]),
          :binary.match(<<10, 65, 30>>, ["(", ")"])
        }
      end
    end
    """

    expected = source |> Kernel.<>("\nNativeBinaryMatch.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "uses :binary.match positions in integer arithmetic", %{ctx: ctx} do
    assert 2 ==
             Batata.execute(
               """
               defmodule NativeBinaryMatchPosition do
                 def main() do
                   case :binary.match("abc", "b") do
                     :nomatch -> 0
                     {position, 1} -> position + 1
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "splits binaries at dynamic byte positions", %{ctx: ctx} do
    source = """
    defmodule NativeSplitBinary do
      def split(binary, position), do: :erlang.split_binary(binary, position)

      def main() do
        binary = <<10, 20, 30, 40>>
        {split(binary, 0), split(binary, 2), split(binary, byte_size(binary))}
      end
    end
    """

    expected = source |> Kernel.<>("\nNativeSplitBinary.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "rejects invalid binary split positions", %{ctx: ctx} do
    source = """
    defmodule InvalidSplitBinary do
      def main(), do: :erlang.split_binary(<<1, 2>>, 3)
    end
    """

    assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
  end

  test "converts valid float binaries with BEAM-compatible syntax", %{ctx: ctx} do
    for value <- ["+1.0", "12.5", "1.5e+2", "1.5E-2", "-0.0"] do
      source = """
      defmodule NativeBinaryToFloat do
        def convert(binary), do: :erlang.binary_to_float(binary)
        def main(), do: convert(#{inspect(value)})
      end
      """

      expected = :erlang.binary_to_float(value)
      actual = Batata.execute(source, ctx)
      assert <<actual::float-64-native>> == <<expected::float-64-native>>
    end
  end

  test "rejects invalid float binaries", %{ctx: ctx} do
    for value <- ["1", "1e2", "1.", ".5", "1.0e", "NaN", :not_binary] do
      source = """
      defmodule InvalidBinaryToFloat do
        def main(), do: :erlang.binary_to_float(#{inspect(value)})
      end
      """

      assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
    end
  end

  test "formats floats with the BEAM-compatible short representation", %{ctx: ctx} do
    values = [
      0.0,
      -0.0,
      0.1,
      12.5,
      100.0,
      1000.0,
      1230.0,
      1200.0,
      0.0001,
      0.00001,
      5.0e-324,
      2.225_073_858_507_201_4e-308,
      1.797_693_134_862_315_7e308
    ]

    source = """
    defmodule NativeFloatToBinary do
      def format(value), do: :erlang.float_to_binary(value, [:short])

      def main() do
        [
          format(0.0),
          format(-0.0),
          format(0.1),
          format(12.5),
          format(100.0),
          format(1000.0),
          format(1230.0),
          format(1200.0),
          format(0.0001),
          format(0.00001),
          format(5.0e-324),
          format(2.2250738585072014e-308),
          format(1.7976931348623157e308)
        ]
      end
    end
    """

    expected = Enum.map(values, &:erlang.float_to_binary(&1, [:short]))
    assert Batata.execute(source, ctx) == expected
  end

  test "rejects invalid short float formatting arguments", %{ctx: ctx} do
    source = """
    defmodule InvalidFloatToBinary do
      def main(), do: :erlang.float_to_binary(42, [:short])
    end
    """

    assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
  end

  test "rejects unsupported float formatting options during lifting", %{ctx: ctx} do
    source = """
    defmodule UnsupportedFloatToBinary do
      def main(), do: :erlang.float_to_binary(1.0, [:compact])
    end
    """

    assert_raise Batata.Lift.Error, ~r/supports only the literal option \[:short\]/, fn ->
      Batata.execute(source, ctx)
    end
  end

  test "converts known atoms to their string names", %{ctx: ctx} do
    source = """
    defmodule NativeAtomToString do
      def render(atom), do: Atom.to_string(atom)

      def main() do
        {render(:alpha), render(nil), render(true), render(false),
         render(:"Elixir.NativeAtomToString")}
      end
    end
    """

    expected = source |> Kernel.<>("\nNativeAtomToString.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "rejects non-atoms passed to Atom.to_string/1", %{ctx: ctx} do
    source = """
    defmodule InvalidAtomToString do
      def main(), do: Atom.to_string(42)
    end
    """

    assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
  end

  test "interns String.to_atom/1 names with literal identity", %{ctx: ctx} do
    source = """
    defmodule NativeStringToAtom do
      def convert(name), do: String.to_atom(name)

      def main() do
        first = convert("dynamic" <> "_key")
        second = convert("dynamic_key")
        alpha = convert("alpha")
        {alpha, alpha == :alpha, first, first == second, convert("λ"), convert("")}
      end
    end
    """

    expected = source |> Kernel.<>("\nNativeStringToAtom.main()") |> Code.eval_string() |> elem(0)
    expected = expected |> put_elem(1, 1) |> put_elem(3, 1)
    assert Batata.execute(source, ctx) == expected
  end

  test "dispatches direct String.to_atom/1 captures", %{ctx: ctx} do
    source = """
    defmodule CapturedStringToAtom do
      def main() do
        convert = &String.to_atom/1
        convert.("captured_atom")
      end
    end
    """

    assert Batata.execute(source, ctx) == :captured_atom
  end

  test "rejects invalid String.to_atom/1 inputs", %{ctx: ctx} do
    non_binary = """
    defmodule NonBinaryStringToAtom do
      def main(), do: String.to_atom(42)
    end
    """

    invalid_utf8 = """
    defmodule InvalidUtf8StringToAtom do
      def main(), do: String.to_atom(<<255>>)
    end
    """

    too_long = """
    defmodule LongStringToAtom do
      def main(), do: String.to_atom(String.duplicate("a", 256))
    end
    """

    assert_raise ArgumentError, fn -> Batata.execute(non_binary, ctx) end
    assert_raise ArgumentError, fn -> Batata.execute(invalid_utf8, ctx) end
    assert_raise SystemLimitError, fn -> Batata.execute(too_long, ctx) end
  end

  test "resolves compile-known and runtime-interned existing atoms", %{ctx: ctx} do
    source = """
    defmodule NativeStringToExistingAtom do
      def existing(name), do: String.to_existing_atom(name)

      def main() do
        dynamic = String.to_atom("runtime" <> "_existing")
        {existing("alpha"), existing("alpha") == :alpha,
         existing("runtime_existing"), existing("runtime_existing") == dynamic}
      end
    end
    """

    assert {:alpha, 1, :runtime_existing, 1} == Batata.execute(source, ctx)
  end

  test "dispatches direct String.to_existing_atom/1 captures", %{ctx: ctx} do
    source = """
    defmodule CapturedStringToExistingAtom do
      def main() do
        convert = &String.to_existing_atom/1
        {convert.("captured_existing"), :captured_existing}
      end
    end
    """

    assert {:captured_existing, :captured_existing} == Batata.execute(source, ctx)
  end

  test "rejects invalid String.to_existing_atom/1 inputs and misses", %{ctx: ctx} do
    cases = [
      "String.to_existing_atom(42)",
      "String.to_existing_atom(<<255>>)",
      ~S|String.to_existing_atom(String.duplicate("a", 256))|,
      ~S|String.to_existing_atom("definitely_missing_existing_atom")|
    ]

    Enum.each(cases, fn expression ->
      source = "defmodule InvalidStringToExistingAtom do\n  def main(), do: #{expression}\nend"
      assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
    end)
  end

  test "concatenates values within the supported binary domain", %{ctx: ctx} do
    assert {"leftright", "value", "three-parts"} ==
             Batata.execute(
               """
               defmodule NativeBinaryConcat do
                 def main() do
                   left = "left"
                   right = "right"
                   {left <> right, "" <> "value", "three" <> "-" <> "parts"}
                 end
               end
               """,
               ctx
             )
  end

  test "fails closed when binary concat receives a non-binary operand", %{ctx: ctx} do
    assert_raise CaseClauseError, fn ->
      Batata.execute(
        """
        defmodule NativeBinaryConcat do
          def main(), do: "value=" <> [1]
        end
        """,
        ctx
      )
    end
  end

  test "executes body-level short-circuit and with Elixir truthiness", %{ctx: ctx} do
    assert {false, nil, 2, 2, 2, 2} ==
             Batata.execute(
               """
               defmodule NativeShortCircuitAnd do
                 def main() do
                   falsy_false = false && 1
                   falsy_nil = nil && 1
                   truthy_zero = 0 && 2
                   truthy_binary = "" && 2
                   truthy_atom = :known && 2
                   truthy_true = true && 2

                   {falsy_false, falsy_nil, truthy_zero, truthy_binary, truthy_atom,
                    truthy_true}
                 end
               end
               """,
               ctx
             )
  end

  test "does not execute the right-hand side of falsy short-circuit and", %{ctx: ctx} do
    assert {false, nil, false} ==
             Batata.execute(
               """
               defmodule NativeShortCircuitAnd do
                 def main() do
                   {false && Kernel.to_string([1]), nil && Kernel.to_string([1]),
                    false && Kernel.to_string([1]) && 1}
                 end
               end
               """,
               ctx
             )
  end

  test "rejects assignments inside the right-hand side of short-circuit and", %{ctx: ctx} do
    for rhs <- ["value = 1", "case 1 do x -> value = x end"] do
      assert_raise Batata.Lift.Error,
                   "assignments in the right-hand side of && are unsupported",
                   fn ->
                     Batata.compile(
                       """
                       defmodule NativeShortCircuitAnd do
                         def main(), do: false && (#{rhs})
                       end
                       """,
                       ctx
                     )
                   end
    end
  end

  test "executes the Decimal.Error message short-circuit kernel", %{ctx: ctx} do
    source = """
    defmodule DecimalErrorMessage do
      def message(%{signal: signal, reason: reason}) do
        reason = reason && ": " <> reason
        "\#{signal}\#{reason}"
      end

      def main() do
        {message(%{signal: :invalid_operation, reason: nil}),
         message(%{signal: :division_by_zero, reason: "ctx"})}
      end
    end
    """

    expected =
      source |> Kernel.<>("\nDecimalErrorMessage.main()") |> Code.eval_string() |> elem(0)

    assert expected == {"invalid_operation", "division_by_zero: ctx"}
    assert Batata.execute(source, ctx) == expected
  end

  test "executes body-level if with Elixir truthiness", %{ctx: ctx} do
    assert {1, 2, 2, 1, 1, 1, nil, 2, 1} ==
             Batata.execute(
               """
               defmodule NativeBodyIf do
                 def main() do
                   {if(true, do: 1, else: 2), if(false, do: 1, else: 2),
                    if(nil, do: 1, else: 2), if(0, do: 1, else: 2),
                    if("", do: 1, else: 2), if(:known, do: 1, else: 2),
                    if(false, do: 1), if(1 == 2, do: 1, else: 2),
                    if(is_integer(1), do: 1, else: 2)}
                 end
               end
               """,
               ctx
             )
  end

  test "executes nested body-level if expressions", %{ctx: ctx} do
    assert {2, 3} ==
             Batata.execute(
               """
               defmodule NativeNestedBodyIf do
                 def choose(outer, inner) do
                   if outer do
                     if inner do
                       1
                     else
                       2
                     end
                   else
                     3
                   end
                 end

                 def main(), do: {choose(true, false), choose(false, true)}
               end
               """,
               ctx
             )
  end

  test "executes only the selected if branch and preserves condition bindings", %{ctx: ctx} do
    assert {7, 8, true} ==
             Batata.execute(
               """
               defmodule NativeLazyBodyIf do
                 def main() do
                   left = if false, do: Kernel.to_string([1]), else: 7
                   right = if true, do: 8, else: Kernel.to_string([1])
                   if value = true, do: {left, right, value}, else: nil
                 end
               end
               """,
               ctx
             )
  end

  test "rejects assignments inside body-level if branches", %{ctx: ctx} do
    for branches <- ["do: (value = 1), else: 2", "do: 1, else: (value = 2)"] do
      assert_raise Batata.Lift.Error, "assignments in if branches are unsupported", fn ->
        Batata.compile(
          """
          defmodule NativeBodyIfAssignment do
            def main(), do: if(true, #{branches})
          end
          """,
          ctx
        )
      end
    end
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

  test "constructs current-module structs with defaults and overrides", %{ctx: ctx} do
    source = """
    defmodule NativeStructConstructor do
      defstruct sign: 1, coef: 0, tags: [:default]

      def main() do
        {%__MODULE__{}, %__MODULE__{sign: -1, tags: [:exact]}}
      end
    end
    """

    expected =
      source |> Kernel.<>("\nNativeStructConstructor.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "constructs current-module exception structs with injected fields", %{ctx: ctx} do
    source = """
    defmodule NativeExceptionConstructor do
      defexception [:message]
      def main(), do: %__MODULE__{message: "exact"}
    end
    """

    expected =
      source |> Kernel.<>("\nNativeExceptionConstructor.main()") |> Code.eval_string() |> elem(0)

    assert Map.from_struct(expected) == %{message: "exact", __exception__: true}
    assert Batata.execute(source, ctx) == expected
  end

  test "rejects unknown and unavailable struct schemas", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/unknown struct fields: \[:unknown\]/, fn ->
      Batata.compile(
        """
        defmodule NativeUnknownStructField do
          defstruct [:value]
          def main(), do: %__MODULE__{unknown: 1}
        end
        """,
        ctx
      )
    end

    assert_raise Batata.Lift.Error, ~r/requires the current-module schema/, fn ->
      Batata.compile(
        """
        defmodule NativeUnavailableStructSchema do
          def main(), do: %Other.Struct{value: 1}
        end
        """,
        ctx
      )
    end
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

  test "executes integer ordering guards on term patterns", %{ctx: ctx} do
    source = """
    defmodule Math do
      def main() do
        case {7, 2} do
          {value, _} when value <= 7 -> 1
          _ -> 0
        end
      end
    end
    """

    beam_result =
      case {7, 2} do
        {value, _} when value <= 7 -> 1
        _ -> 0
      end

    assert 1 == beam_result
    assert 1 == Batata.execute(source, ctx)
  end

  test "executes literal equality guards on term patterns", %{ctx: ctx} do
    source = """
    defmodule Math do
      def main() do
        case {[], false} do
          {list, pretty} when list == [] and pretty !== true -> 1
          _ -> 0
        end
      end
    end
    """

    beam_result =
      case {[], false} do
        {list, pretty} when list == [] and pretty !== true -> 1
        _ -> 0
      end

    assert 1 == beam_result
    assert 1 == Batata.execute(source, ctx)
  end

  test "executes function arity guards on term patterns", %{ctx: ctx} do
    assert :matched ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   case {fn value -> value end, :ignored} do
                     {fun, _result} when is_function(fun, 1) -> :matched
                     _ -> :missed
                   end
                 end
               end
               """,
               ctx
             )
  end

  test "rejects unrefined term-pattern integer arithmetic before verification", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/requires an is_integer\/1 guard/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def main() do
            case {100, 7} do
              {value, divisor} -> rem(value, divisor)
              _ -> 0
            end
          end
        end
        """,
        ctx
      )
    end
  end

  test "rejects an unprotected integer BIF in a term-pattern guard", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/unsupported guard on term pattern/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def main() do
            case {100, 10} do
              {value, _} when rem(value, 10) == 0 -> 1
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

  test "executes arithmetic on byte and utf8 pattern bindings", %{ctx: ctx} do
    assert 84 ==
             Batata.execute(
               """
               defmodule Math do
                 def byte(<<value::8>>), do: value + 1
                 def unicode(<<value::utf8>>), do: value - 1
                 def main(), do: byte(<<41>>) + unicode(<<43::utf8>>)
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

  test "matches Jason-shaped wildcard bitstring tails", %{ctx: ctx} do
    source = """
    defmodule WildcardBitstringTail do
      def classify(data) do
        case data do
          <<first::8, _::bits>> -> {:nonempty, first}
          <<_::bits>> -> :empty
        end
      end

      def main(), do: {classify(<<>>), classify(<<1>>), classify(<<2, 3, 4>>)}
    end
    """

    expected =
      source |> Kernel.<>("\nWildcardBitstringTail.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "rejects unsupported binary segments explicitly", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/unsupported binary segment/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def main() do
            case <<1, 2>> do
              <<x::24>> -> 1
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

  test "executes literal binary prefix patterns with native parity", %{ctx: ctx} do
    source = """
    defmodule NativeLiteralBinaryPattern do
      def decode(<<"rue", rest::bits>>), do: {:matched, rest}
      def decode(<<"", rest::bits>>), do: {:empty, rest}

      def exact(<<"ok">>), do: :exact
      def exact(_), do: :mismatch

      def main() do
        {decode("rue!"), decode("ru!"), exact("ok"), exact("ok!"), exact("no")}
      end
    end
    """

    expected =
      source
      |> Kernel.<>("\nNativeLiteralBinaryPattern.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(source, ctx) == expected
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

  test "constructs dynamic utf8 segments with native result parity", %{ctx: ctx} do
    source = """
    defmodule NativeUtf8Construction do
      def encode(codepoint), do: <<codepoint::utf8>>

      def main() do
        {encode(0x24), encode(0xE9), encode(0x20AC), encode(0x1F642),
         <<91, 0xE9::utf8, 93>>}
      end
    end
    """

    expected =
      source
      |> Kernel.<>("\nNativeUtf8Construction.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(source, ctx) == expected
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
  test "executes Jason-shaped range and set guards on binary segments", %{ctx: ctx} do
    assert 123 ==
             Batata.execute(
               """
               defmodule Math do
                 def classify(<<byte::8, _rest::binary>>) when byte in ?0..?9, do: byte
                 def classify(<<byte::8, _rest::binary>>) when byte in ~c"eE", do: byte + 1
                 def classify(_), do: 0

                 def main() do
                   classify(<<53>>) + classify(<<69>>)
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
  test "raises FunctionClauseError when no function clause matches", %{ctx: ctx} do
    error =
      assert_raise FunctionClauseError, fn ->
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
              f(3)
            end
          end
          """,
          ctx
        )
      end

    assert error.module == Math
    assert error.function == :f
    assert error.arity == 1
    assert error.args == [3]
  end

  test "executes a single guarded function and preserves guard failures", %{ctx: ctx} do
    source = fn argument ->
      """
      defmodule SingleGuardedClause do
        def new(values) when is_list(values), do: values
        def main(), do: new(#{argument})
      end
      """
    end

    assert [1, 2] == Batata.execute(source.("[1, 2]"), ctx)

    error =
      assert_raise FunctionClauseError, fn ->
        Batata.execute(source.(":not_a_list"), ctx)
      end

    assert error.module == SingleGuardedClause
    assert error.function == :new
    assert error.arity == 1
    assert error.args == [:not_a_list]
  end

  test "keeps same-name functions distinct by arity", %{ctx: ctx} do
    assert 16 ==
             Batata.execute(
               """
               defmodule ArityQualifiedSymbols do
                 def get_and_update(a, b, c), do: a + b + c
                 def get_and_update(a, b, c, d), do: a + b + c + d

                 def main(), do: get_and_update(1, 2, 3) + get_and_update(1, 2, 3, 4)
               end
               """,
               ctx
             )
  end

  test "keeps encoded symbols separate from source names and recursive arities", %{ctx: ctx} do
    assert 109 ==
             Batata.execute(
               """
               defmodule AdversarialFunctionSymbols do
                 def abc(a, b, c), do: a + b + c
                 def __batata_fn_616263_3(), do: 100

                 def walk(0), do: 0
                 def walk(n), do: walk(n - 1, 1)
                 def walk(0, acc), do: acc
                 def walk(n, acc), do: walk(n - 1, acc + 1)

                 def main(), do: abc(1, 2, 3) + __batata_fn_616263_3() + walk(3)
               end
               """,
               ctx
             )
  end

  test "executes combined guards over every single-clause argument", %{ctx: ctx} do
    source = fn right ->
      """
      defmodule CombinedSingleGuard do
        def same_list(left, right)
            when is_list(left) and is_list(right) and left == right,
            do: :same

        def main(), do: same_list([1], #{right})
      end
      """
    end

    assert :same == Batata.execute(source.("[1]"), ctx)

    error =
      assert_raise FunctionClauseError, fn ->
        Batata.execute(source.("[2]"), ctx)
      end

    assert error.module == CombinedSingleGuard
    assert error.function == :same_list
    assert error.arity == 2
    assert error.args == [[1], [2]]
  end

  test "executes a scalar single-clause guard", %{ctx: ctx} do
    assert 8 ==
             Batata.execute(
               """
               defmodule ScalarSingleGuard do
                 def positive(value) when is_integer(value) and value > 0, do: value + 1
                 def main(), do: positive(7)
               end
               """,
               ctx
             )
  end

  test "executes a function-arity single-clause guard", %{ctx: ctx} do
    assert 3 ==
             Batata.execute(
               """
               defmodule FunctionSingleGuard do
                 def call(fun) when is_function(fun, 1), do: fun.(3)
                 def main(), do: call(fn value -> value end)
               end
               """,
               ctx
             )
  end

  test "distinguishes function values and their arities", %{ctx: ctx} do
    source = """
    defmodule FunctionGuards do
      def function?(value) when is_function(value), do: 1
      def function?(_value), do: 0
      def binary?(value) when is_function(value, 2), do: 1
      def binary?(_value), do: 0

      def main() do
        unary = fn value -> value end
        binary = fn left, right -> left + right end
        function?(unary) + function?(7) + binary?(binary) + binary?(unary)
      end
    end
    """

    assert 2 == Batata.execute(source, ctx)
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

  test "executes clause-local trailing bindings with BEAM semantics", %{ctx: ctx} do
    source = """
    defmodule ClauseLocalTailOracle do
      def choose(0, left) when is_integer(left), do: left + 1
      def choose(_, right) when is_integer(right), do: right + 2

      def ignore(0, _), do: 11
      def ignore(_, value), do: value

      def delete_key([{key, _} | tail], key), do: delete_key(tail, key)
      def delete_key([{_, _} = pair | tail], key), do: [pair | delete_key(tail, key)]
      def delete_key([], _key), do: []

      def main() do
        {
          choose(0, 4),
          choose(1, 4),
          ignore(0, 7),
          ignore(1, 7),
          delete_key([a: 1, b: 2, a: 3], :a)
        }
      end
    end
    """

    expected =
      source |> Kernel.<>("\nClauseLocalTailOracle.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "preserves term-valued arguments across inferred local-call signatures", %{ctx: ctx} do
    source = """
    defmodule TermArgumentModes do
      def keep(0, value) when is_atom(value), do: value
      def keep(_, value), do: value

      def forward(value), do: keep(0, value)

      def main() do
        {forward(:original), forward(<<1, 2>>), forward(7)}
      end
    end
    """

    expected =
      source |> Kernel.<>("\nTermArgumentModes.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "executes :lists.keyfind/3 and :lists.reverse/1,2 with BEAM semantics", %{ctx: ctx} do
    source = """
    defmodule ListsOracle do
      def main() do
        {
          :lists.keyfind(1, 1, [{1.0, :float}, :skip]),
          :lists.keyfind(nil, 2, [{:short}, {:ok, nil}]),
          :lists.keyfind(:missing, 1, [{:ok, 1}]),
          :lists.reverse([1, 2, 3]),
          :lists.reverse([1, 2, 3], []),
          :erlang.tl(:erlang.tl(:lists.reverse([1, 2], :tail)))
        }
      end
    end
    """

    expected = source |> Kernel.<>("\nListsOracle.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "executes Keyword.get/2,3 with first-key and default semantics", %{ctx: ctx} do
    source = """
    defmodule KeywordOracle do
      def main() do
        {
          Keyword.get([mode: :first, mode: :second], :mode),
          Keyword.get([mode: false], :mode, :fallback),
          Keyword.get([mode: nil], :mode, :fallback),
          Keyword.get([mode: :first], :missing, :fallback),
          Keyword.get([], :missing)
        }
      end
    end
    """

    expected = source |> Kernel.<>("\nKeywordOracle.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "resumes budgeted Keyword.get/3 traversal", %{ctx: ctx} do
    source = """
    defmodule BudgetedKeyword do
      def main(), do: Keyword.get([a: 1, b: 2, c: 3, d: :found], :d, :missing)
    end
    """

    assert Batata.execute(source, ctx) == :found

    for budget <- [1, 2] do
      assert Batata.execute(source, ctx, reduction_budget: budget) == :found
    end
  end

  test "raises ArgumentError for invalid :lists arguments", %{ctx: ctx} do
    for expression <- [
          ":lists.keyfind(:key, 0, [])",
          ":lists.keyfind(:key, 1, :not_a_list)",
          ":lists.keyfind(:key, 1, [{:ok, 1} | :tail])",
          ":lists.reverse([1 | :tail], [])"
        ] do
      assert_raise ArgumentError, fn ->
        Batata.execute(
          """
          defmodule InvalidLists do
            def main(), do: #{expression}
          end
          """,
          ctx
        )
      end
    end
  end

  test "resumes budgeted :lists traversal without misclassifying a live cons", %{ctx: ctx} do
    keyfind_source = """
    defmodule BudgetedKeyfind do
      def main(), do: :lists.keyfind(5, 1, [{1, :a}, {2, :b}, {3, :c}, {4, :d}, {5, :e}])
    end
    """

    reverse_source = """
    defmodule BudgetedReverse do
      def main(), do: :lists.reverse([1, 2, 3, 4, 5], [])
    end
    """

    for budget <- [1, 2] do
      assert Batata.execute(keyfind_source, ctx, reduction_budget: budget) == {5, :e}
      assert Batata.execute(reverse_source, ctx, reduction_budget: budget) == [5, 4, 3, 2, 1]
    end
  end

  test "preserves trailing arguments in multi-clause FunctionClauseError", %{ctx: ctx} do
    error =
      assert_raise FunctionClauseError, fn ->
        Batata.execute(
          """
          defmodule ClauseLocalTailFailure do
            def only(1, first), do: first
            def only(2, second), do: second
            def main(), do: only(3, 4)
          end
          """,
          ctx
        )
      end

    assert error.module == ClauseLocalTailFailure
    assert error.function == :only
    assert error.arity == 2
    assert error.args == [3, 4]
  end

  test "executes generated default wrappers with hygienic variable contexts", %{ctx: ctx} do
    source = """
    defmodule GeneratedDefaultWrapper do
      def choose(left, right, fallback \\\\ 5), do: left + right + fallback

      def main() do
        choose(1, 2) + choose(3, 4, 6)
      end
    end
    """

    expected =
      source |> Kernel.<>("\nGeneratedDefaultWrapper.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "matches and binds validated struct patterns in trailing arguments", %{ctx: ctx} do
    source = """
    defmodule DecimalTailPatterns do
      defstruct sign: 1, coef: 0

      def classify(%__MODULE__{sign: sign}, %__MODULE__{sign: sign} = right),
        do: {:same, right}

      def classify(%__MODULE__{}, %__MODULE__{sign: sign}), do: {:different, sign}

      def main() do
        {
          classify(%__MODULE__{sign: 1}, %__MODULE__{sign: 1, coef: 7}),
          classify(%__MODULE__{sign: 1}, %__MODULE__{sign: -1, coef: 8})
        }
      end
    end
    """

    expected =
      source |> Kernel.<>("\nDecimalTailPatterns.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "matches and binds Jason-shaped tuple patterns in trailing arguments", %{ctx: ctx} do
    source = """
    defmodule JasonTupleTailPatterns do
      def encode(:atom, {escape, encode_map}), do: {:atom, escape, encode_map}
      def encode(:list, {escape, encode_map, depth}), do: {:list, escape, encode_map, depth}
      def encode(_, {_escape, _encode_map}), do: :pair
      def encode(_, _options), do: :other

      def main() do
        {
          encode(:atom, {:unicode, :strict}),
          encode(:list, {:json, :maps, 2}),
          encode(:unknown, {:unicode, :strict}),
          encode(:unknown, :invalid)
        }
      end
    end
    """

    expected =
      source |> Kernel.<>("\nJasonTupleTailPatterns.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end

  test "rejects unreviewed binary literals in multi-clause trailing positions", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/trailing arguments must be variables, wildcards/, fn ->
      Batata.execute(
        """
        defmodule Math do
          def f(1, "two") do
            1
          end

          def f(_, _) do
            0
          end

          def main() do
            f(1, "two")
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

  test "rejects dynamic application without a module-local closure dispatch", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/dynamic_apply_without_local_dispatch/, fn ->
      Batata.execute(
        """
        defmodule ExternalDynamicApply do
          def apply(fun, value), do: fun.(value)
          def main(), do: 0
        end
        """,
        ctx
      )
    end
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

  test "receives DOWN when a monitored actor exits normally", %{ctx: ctx} do
    assert 42 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   child = spawn(fn -> 7 end)
                   Process.monitor(child)

                   receive do
                     {:DOWN, _ref, :process, _pid, :normal} -> 42
                   after
                     :infinity -> 0
                   end
                 end
               end
               """,
               ctx,
               workers: 1,
               reduction_budget: 2
             )
  end

  test "trap_exit turns an explicit linked exit into a message", %{ctx: ctx} do
    assert 43 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   Process.flag(:trap_exit, true)
                   child = spawn(fn -> 7 end)
                   Process.link(child)
                   Process.exit(child, :boom)

                   receive do
                     {:EXIT, _pid, :boom} -> 43
                   after
                     :infinity -> 0
                   end
                 end
               end
               """,
               ctx,
               workers: 1,
               reduction_budget: 2
             )
  end

  test "wakes a parallel selective receive without losing the send", %{ctx: ctx} do
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
                   after
                     :infinity -> 0
                   end
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

  test "rejects multiple receive sites on parallel workers", %{ctx: ctx} do
    assert_raise ArgumentError,
                 ~r/parallel workers currently support at most one receive site/,
                 fn ->
                   Batata.execute(
                     """
                     defmodule Math do
                       def main() do
                         receive do
                           1 -> 1
                         end

                         receive do
                           2 -> 2
                         end
                       end
                     end
                     """,
                     ctx,
                     workers: 2,
                     reduction_budget: 2
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

  test "process_cap is an initial allocation that grows on spawn (#50 stage 2)", %{ctx: ctx} do
    # cap = 1: the spawned closure still runs (the table grows dynamically),
    # but main's direct send wins the FIFO receive before the actor's message.
    assert 0 ==
             Batata.execute(
               """
               defmodule Math do
                 def main() do
                   me = self()
                   spawn(fn -> send(me, 7) end)
                   send(me, 42)

                   receive do
                     42 -> 0
                     _ -> 1
                   end
                 end
               end
               """,
               ctx,
               process_cap: 1
             )
  end

  test "rejects an out-of-range process_cap", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/process_cap must be an integer between 1 and 4096/, fn ->
      Batata.execute("defmodule Math do\n  def main() do\n    1\n  end\nend\n", ctx,
        process_cap: 0
      )
    end
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

  test "try applies else only to normal completion", %{ctx: ctx} do
    source = """
    defmodule TryElse do
      def normal() do
        try do
          7
        catch
          _ -> 0
        else
          value when is_integer(value) -> value + 1
        end
      end

      def thrown() do
        try do
          throw(9)
        catch
          value when is_integer(value) -> value + 2
        else
          value when is_integer(value) -> value + 100
        end
      end

      def main(), do: {normal(), thrown()}
    end
    """

    expected = source |> Kernel.<>("\nTryElse.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "raises TryClauseError when no else clause matches", %{ctx: ctx} do
    source = """
    defmodule UnmatchedTryElse do
      def main() do
        try do
          :unexpected
        catch
          _ -> :caught
        else
          :expected -> :ok
        end
      end
    end
    """

    error = assert_raise TryClauseError, fn -> Batata.execute(source, ctx) end
    assert error.term == :unexpected
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

  test "try matches Jason-shaped throw kind and struct value patterns", %{ctx: ctx} do
    source = """
    defmodule JasonThrowPattern do
      defstruct message: nil

      def main() do
        try do
          throw(%__MODULE__{message: "boom"})
        catch
          :throw, %__MODULE__{} = error -> {:error, error.message}
          :error, _error -> :wrong_kind
        end
      end
    end
    """

    expected = source |> Kernel.<>("\nJasonThrowPattern.main()") |> Code.eval_string() |> elem(0)
    assert Batata.execute(source, ctx) == expected
  end

  test "executes nested composite terms under abstract !ex.term representation", %{ctx: ctx} do
    assert {1, [2, 3], %{foo: "bar"}, <<4, 5, 6>>} ==
             Batata.execute(
               """
               defmodule AbstractTermDemo do
                 def build_nested() do
                   {1, [2, 3], %{foo: "bar"}, <<4, 5, 6>>}
                 end

                 def main() do
                   build_nested()
                 end
               end
               """,
               ctx
             )
  end

  test "JIT turns a physical arena quota breach into the typed OOM boundary", %{ctx: ctx} do
    assert_raise Batata.ResultError, "native arena allocation failed", fn ->
      Batata.execute(
        """
        defmodule QuotaJIT do
          def main(), do: [1]
        end
        """,
        ctx,
        memory_quota_bytes: 0
      )
    end
  end

  test "JIT calibrates the proved maximum against result-owned native telemetry", %{ctx: ctx} do
    report =
      Batata.execute_with_memory_report(
        """
        defmodule CalibratedJIT do
          def main(), do: {1, [2, 3]}
        end
        """,
        ctx,
        memory_quota_bytes: 4_096
      )

    assert report.result == {1, [2, 3]}
    assert report.telemetry["arena_high_water_bytes"] > 0
    assert report.telemetry["arena_high_water_bytes"] <= 4_096
    assert report.telemetry["arena_limit_bytes"] == 4_096
    assert report.calibration["status"] == "matched"
    assert report.calibration["plan_hash"] == "sha256:" <> Plan.digest(report.plan)
  end
end
