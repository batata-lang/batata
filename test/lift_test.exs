defmodule Batata.LiftTest do
  use Batata.Case, async: true

  alias Batata.{Frontend, Lift}

  @result_accessor_ops Enum.flat_map(
                         [
                           "ex.result_destroy",
                           "ex.result_root_kind",
                           "ex.result_root_word",
                           "ex.result_exception_kind",
                           "ex.result_exception_reason",
                           "ex.result_term_kind",
                           "ex.result_atom_name",
                           "ex.result_term_length",
                           "ex.result_term_get",
                           "ex.term_export",
                           "ex.term_import",
                           "ex.exported_clone",
                           "ex.exported_destroy",
                           "ex.exported_length",
                           "ex.exported_get",
                           "ex.term_handle_export",
                           "ex.term_handle_destroy"
                         ],
                         &["ex.func", &1, "ex.return"]
                       )

  @execution_driver_ops [
                          "ex.func",
                          "ex.call",
                          "ex.unbox",
                          "ex.runtime_create",
                          "ex.runtime_enter",
                          "ex.lit",
                          "ex.process_table_reset",
                          "ex.runtime_leave",
                          "ex.result_create",
                          "ex.return"
                        ] ++ @result_accessor_ops

  defp lift!(source, ctx) when is_binary(source) do
    source
    |> Frontend.from_source()
    |> Lift.module_to_ir(ctx: ctx)
    |> Beaver.Deferred.resolve(ctx)
    |> MLIR.verify!()
  end

  defp lift!(ast, ctx) do
    ast
    |> Frontend.from_ast()
    |> Lift.module_to_ir(ctx: ctx)
    |> Beaver.Deferred.resolve(ctx)
    |> MLIR.verify!()
  end

  defp op_names(module) do
    {_, ops} =
      Beaver.Walker.postwalk(module, [], fn
        %MLIR.Operation{} = op, acc -> {op, [op | acc]}
        element, acc -> {element, acc}
      end)

    ops |> Enum.reverse() |> Enum.map(&MLIR.Operation.name/1)
  end

  defp operations(module) do
    {_, ops} =
      Beaver.Walker.postwalk(module, [], fn
        %MLIR.Operation{} = op, acc -> {op, [op | acc]}
        element, acc -> {element, acc}
      end)

    Enum.reverse(ops)
  end

  test "emits function groups in deterministic symbol order", %{ctx: ctx} do
    rendered =
      lift!(
        """
        defmodule StableFunctionOrder do
          def zeta(value), do: value
          def alpha(value), do: value
        end
        """,
        ctx
      )
      |> MLIR.to_string(generic: true)

    alpha = Batata.Symbol.function(:alpha, 1)
    zeta = Batata.Symbol.function(:zeta, 1)

    assert :binary.match(rendered, alpha) < :binary.match(rendered, zeta)
  end

  test "lifts literals, bindings and addition into ex IR", %{ctx: ctx} do
    module =
      lift!(
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

    assert Enum.sort(op_names(module)) ==
             Enum.sort(
               @execution_driver_ops ++
                 [
                   "builtin.module",
                   "ex.func",
                   "ex.lit",
                   "ex.lit",
                   "ex.lit",
                   "ex.add",
                   "ex.add",
                   "ex.return"
                 ]
             )

    rendered = MLIR.to_string(module, generic: true)
    runtime_create = first_index(rendered, ~s{"ex.runtime_create"})
    runtime_enter = first_index(rendered, ~s{"ex.runtime_enter"})
    process_table_reset = first_index(rendered, ~s{"ex.process_table_reset"})
    entry_call = first_index(rendered, ~s{"ex.call"})
    result_create = first_index(rendered, ~s{"ex.result_create"})
    runtime_leave = first_index(rendered, ~s{"ex.runtime_leave"})

    assert runtime_create < runtime_enter
    assert runtime_enter < process_table_reset
    assert process_table_reset < entry_call
    assert entry_call < result_create
    assert result_create < runtime_leave
  end

  test "preserves the signed 61-bit integer literal boundaries", %{ctx: ctx} do
    max = 1_152_921_504_606_846_975
    min = -1_152_921_504_606_846_976

    assert Batata.execute(integer_source("#{max}"), ctx) == max
    assert Batata.execute(integer_source("[#{max}]"), ctx) == [max]
    assert Batata.execute(integer_source("Integer.to_string(#{max})"), ctx) == to_string(max)

    assert Batata.execute(integer_source("#{min}"), ctx) == min
    assert Batata.execute(integer_source("[#{min}]"), ctx) == [min]
    assert Batata.execute(integer_source("Integer.to_string(#{min})"), ctx) == to_string(min)
    assert Batata.execute(integer_source("[0 - 1_152_921_504_606_846_976]"), ctx) == [min]
  end

  test "rejects integer literals outside the signed 61-bit term domain", %{ctx: ctx} do
    for literal <- [
          "1_152_921_504_606_846_976",
          "-1_152_921_504_606_846_977",
          "10_000_000_000_000_000_000",
          "-9_223_372_036_854_775_808"
        ] do
      error =
        assert_raise Batata.Lift.Error, fn ->
          Batata.compile(integer_source("[#{literal}]"), ctx)
        end

      assert error.message =~ ~r/outside the signed (61-bit term|64-bit scalar) domain/
    end
  end

  test "keeps the full i64 scalar path for packed runtime representations", %{ctx: ctx} do
    packed = 6_311_074_175_999_999_996
    assert Batata.execute(integer_source("#{packed}"), ctx) == packed
  end

  test "lifts tuple and list literals plus predicates into ex IR", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            is_tuple({1, [2, 3]})
          end
        end
        """,
        ctx
      )

    assert Enum.sort(op_names(module)) ==
             Enum.sort(
               @execution_driver_ops ++
                 [
                   "builtin.module",
                   "ex.box",
                   "ex.box",
                   "ex.box",
                   "ex.box",
                   "ex.box",
                   "ex.func",
                   "ex.lit",
                   "ex.lit",
                   "ex.lit",
                   "ex.list",
                   "ex.tuple",
                   "ex.is_tuple",
                   "ex.return"
                 ]
             )
  end

  test "lifts map, binary and string literals into ex IR", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            is_map(%{1 => 2})
            is_binary(<<1, 2>>)
          end
        end
        """,
        ctx
      )

    assert Enum.sort(op_names(module)) ==
             Enum.sort(
               @execution_driver_ops ++
                 [
                   "builtin.module",
                   "ex.box",
                   "ex.box",
                   "ex.box",
                   "ex.box",
                   "ex.box",
                   "ex.box",
                   "ex.func",
                   "ex.lit",
                   "ex.lit",
                   "ex.lit",
                   "ex.lit",
                   "ex.map",
                   "ex.binary",
                   "ex.is_map",
                   "ex.is_binary",
                   "ex.return"
                 ]
             )
  end

  test "selects the actor driver for potentially raising map updates", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            map = %{value: 1}
            %{map | value: 2}
          end
        end
        """,
        ctx
      )

    assert "ex.worker_run" in op_names(module)
  end

  test "lifts an empty list into ex IR", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            is_list([])
          end
        end
        """,
        ctx
      )

    assert Enum.sort(op_names(module)) ==
             Enum.sort(
               @execution_driver_ops ++
                 [
                   "builtin.module",
                   "ex.box",
                   "ex.func",
                   "ex.list",
                   "ex.is_list",
                   "ex.return"
                 ]
             )
  end

  test "lifts case into ex.case/ex.clause with patterns and catch-all", %{ctx: ctx} do
    module =
      lift!(
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

    assert Enum.sort(op_names(module)) ==
             Enum.sort(
               @execution_driver_ops ++
                 [
                   "builtin.module",
                   "ex.func",
                   "ex.lit",
                   "ex.lit",
                   "ex.lit",
                   "ex.lit",
                   "ex.case",
                   "ex.clause",
                   "ex.clause",
                   "ex.clause",
                   "ex.yield",
                   "ex.yield",
                   "ex.yield",
                   "ex.return"
                 ]
             )
  end

  test "lifts case guards into ex.clause guard operands", %{ctx: ctx} do
    module =
      lift!(
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

    names = op_names(module)
    assert "ex.case" in names
    assert Enum.count(names, &(&1 == "ex.clause")) == 2
    assert "ex.cmp" in names
  end

  test "lifts term patterns into guard-only ex.clause clauses", %{ctx: ctx} do
    module =
      lift!(
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

    names = op_names(module)
    assert "ex.case" in names
    assert Enum.count(names, &(&1 == "ex.clause")) == 2
    assert "ex.is_tuple" in names
    assert "ex.tuple_length" in names
    assert "ex.tuple_get" in names
  end

  test "lifts atom-keyed map subset patterns", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            case %{position: nil, extra: 1} do
              %{position: position} -> is_atom(position)
              _ -> 0
            end
          end
        end
        """,
        ctx
      )

    names = op_names(module)
    assert "ex.is_map" in names
    assert "ex.map_fetch" in names
    assert "ex.tuple_get" in names
  end

  test "lifts literal and nested values in atom-keyed map patterns", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            case %{position: 1, nested: %{status: :ok}} do
              %{position: 1, nested: %{status: :ok}} = whole -> whole
              _ -> %{}
            end
          end
        end
        """,
        ctx
      )

    names = op_names(module)
    assert Enum.count(names, &(&1 == "ex.map_fetch")) == 3
    assert "ex.term_eq" in names
  end

  test "rejects non-atom map pattern keys", %{ctx: ctx} do
    assert_raise Batata.Lift.Error, ~r/map patterns only support/, fn ->
      lift!(
        """
        defmodule Math do
          def main() do
            case %{position: 1} do
              %{"position" => value} -> value
              _ -> 0
            end
          end
        end
        """,
        ctx
      )
    end
  end

  test "lifts term pattern guards into the eager match condition", %{ctx: ctx} do
    module =
      lift!(
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

    names = op_names(module)
    assert "ex.case" in names
    assert "ex.is_integer" in names
    assert "arith.andi" in names
  end

  test "lifts binary patterns into guard-only ex.clause clauses", %{ctx: ctx} do
    module =
      lift!(
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

    names = op_names(module)
    assert "ex.case" in names
    assert "ex.is_binary" in names
    assert "ex.binary_length" in names
    assert "ex.binary_get" in names
    assert "ex.binary_slice" in names
  end

  test "expands literal binary pattern prefixes into ordered bytes", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def decode(<<"rue", rest::bits>>), do: byte_size(rest)
          def decode(_), do: -1
          def main(), do: decode("rue!")
        end
        """,
        ctx
      )

    names = op_names(module)
    assert Enum.count(names, &(&1 == "ex.binary_get")) >= 3
    assert "ex.binary_slice" in names
  end

  test "lifts utf8 binary patterns with dynamic offsets", %{ctx: ctx} do
    module =
      lift!(
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

    names = op_names(module)
    assert "ex.case" in names
    assert "ex.binary_utf8_width" in names
    assert "ex.binary_utf8_get" in names
    assert "ex.binary_slice" in names
  end

  test "refines byte and utf8 pattern bindings to scalar integers", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def byte(<<value::8>>), do: value + 1
          def unicode(<<value::utf8>>), do: value - 1
          def main(), do: 0
        end
        """,
        ctx
      )

    assert MLIR.verify?(module)
    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ ~r/"ex\.binary_get".*"ex\.to_int"/s
    assert rendered =~ ~r/"ex\.binary_utf8_get".*"ex\.to_int"/s
  end

  test "refines :binary.match tuple fields for arithmetic", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
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

    assert MLIR.verify?(module)
    assert MLIR.to_string(module, generic: true) =~ ~r/"ex\.tuple_get".*"ex\.to_int"/s
  end

  test "preserves scalar values assigned to hygienic macro variables", %{ctx: ctx} do
    variable = {:value, [generated: true], Batata.GeneratedMacro}

    snapshot = %Frontend.Module{
      name: GeneratedMacro,
      definitions: [
        %Frontend.Definition{
          kind: :def,
          name: :main,
          arity: 0,
          clauses: [
            %Frontend.Clause{
              patterns: [],
              body_ast:
                {:__block__, [],
                 [
                   {:=, [], [variable, {:+, [], [1, 2]}]},
                   {:+, [], [variable, 3]}
                 ]}
            }
          ]
        }
      ]
    }

    module =
      snapshot
      |> Lift.module_to_ir(ctx: ctx)
      |> Beaver.Deferred.resolve(ctx)
      |> MLIR.verify!()

    refute MLIR.to_string(module, generic: true) =~ ~r/"ex\.add".*!ex\.term/
  end

  test "lifts dynamic utf8 binary construction through byte iodata", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def encode(codepoint), do: <<91, codepoint::utf8, 93>>
          def main(), do: encode(0x1F642)
        end
        """,
        ctx
      )

    names = op_names(module)
    assert "ex.div" in names
    assert "ex.rem" in names
    assert "ex.binary" in names
    assert "ex.iodata_to_binary" in names
    assert "ex.raise" in names
    refute "ex.unbound" in names
  end

  test "lifts quoted utf8 construction type contexts", %{ctx: ctx} do
    codepoint = Macro.var(:codepoint, nil)

    quoted_binary =
      quote generated: true do
        <<unquote(codepoint)::utf8>>
      end

    module =
      lift!(
        quote do
          defmodule Math do
            def encode(unquote(codepoint)), do: unquote(quoted_binary)
            def main, do: encode(0x1F642)
          end
        end,
        ctx
      )

    names = op_names(module)
    assert "ex.iodata_to_binary" in names
    refute "ex.unbound" in names
  end

  test "lifts multi-clause functions into a case dispatch", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def kind(<<>>) do
            1
          end

          def kind(<<_h::8, _t::binary>>) do
            2
          end

          def kind(_) do
            0
          end

          def main() do
            kind(<<1>>)
          end
        end
        """,
        ctx
      )

    names = op_names(module)
    assert Enum.count(names, &(&1 == "ex.func")) == 20
    assert Enum.count(names, &(&1 == "ex.case")) == 1
    assert Enum.count(names, &(&1 == "ex.clause")) == 3
  end

  test "lifts tail-recursive binary scanners into scf.while cursor loops", %{ctx: ctx} do
    module =
      lift!(
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
            count(<<1, 2>>)
          end
        end
        """,
        ctx
      )

    names = op_names(module)
    assert "scf.while" in names
    assert "scf.condition" in names
    refute Enum.any?(names, &(&1 == "ex.case"))
  end

  test "lifts reduce-style accumulator scanners into scf.while cursor loops", %{ctx: ctx} do
    module =
      lift!(
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
            reduce(<<1, 2>>, 0)
          end
        end
        """,
        ctx
      )

    names = op_names(module)
    assert "scf.while" in names
    refute Enum.any?(names, &(&1 == "ex.case"))
  end

  test "defers rest-slice materialization into the clause body when unguarded", %{ctx: ctx} do
    module =
      lift!(
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

    rendered = MLIR.to_string(module, generic: true)
    assert first_index(rendered, ~s{"ex.case"}) < first_index(rendered, "ex.binary_slice")
  end

  test "keeps rest-slice materialization eager when a guard is present", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            case <<1, 2>> do
              <<h::8, t::binary>> when is_binary(t) -> 1
              _ -> 0
            end
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    assert first_index(rendered, "ex.binary_slice") < first_index(rendered, ~s{"ex.case"})
  end

  test "lifts integer range membership guards on binary segments", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def digit(<<byte::8, rest::binary>>) when byte in ?0..?9 do
            byte
          end

          def digit(_), do: 0
          def main(), do: digit(<<53>>)
        end
        """,
        ctx
      )

    names = op_names(module)
    assert "ex.is_integer" in names
    assert "ex.to_int" in names
    assert Enum.count(names, &(&1 == "ex.cmp")) >= 2
    assert "arith.andi" in names
  end

  test "lifts integer set membership guards on binary segments", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def exponent(<<byte::8, rest::binary>>) when byte in ~c"eE" do
            byte
          end

          def exponent(_), do: 0
          def main(), do: exponent(<<101>>)
        end
        """,
        ctx
      )

    names = op_names(module)
    assert "arith.ori" in names
    assert "arith.andi" in names
  end

  test "extracts anonymous function literals into synthetic ex.funcs", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            (fn x -> x + 1 end).(2)
          end
        end
        """,
        ctx
      )

    names = op_names(module)
    # The execution driver, __batata_entry, extracted __fn_* and closure dispatch.
    assert Enum.count(names, &(&1 == "ex.func")) == 21
    assert "ex.call" in names

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "__fn_"
    assert rendered =~ "__fn_dispatch"
  end

  defp integer_source(expression) do
    """
    defmodule IntegerLiteralBoundary do
      def main(), do: #{expression}
    end
    """
  end

  defp first_index(string, pattern) do
    case :binary.match(string, pattern) do
      {index, _length} -> index
      :nomatch -> -1
    end
  end

  test "lifts local calls with callee and arity attributes", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            add(1, 2)
          end
        end
        """,
        ctx
      )

    assert "ex.call" in op_names(module)

    call = module |> operations() |> Enum.find(&(MLIR.Operation.name(&1) == "ex.call"))

    attributes = Beaver.Walker.attributes(call)

    assert attributes["callee"]
           |> MLIR.CAPI.mlirStringAttrGetValue()
           |> MLIR.to_string() == Batata.Symbol.function(:add, 2)

    assert attributes["arity"]
           |> MLIR.CAPI.mlirIntegerAttrGetValueInt()
           |> Beaver.Native.to_term() == 2
  end

  test "lifts function parameters into block arguments", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def add(a, b) do
            a + b
          end
        end
        """,
        ctx
      )

    func =
      module
      |> operations()
      |> Enum.find(&(MLIR.Operation.name(&1) == "ex.func"))

    [block] =
      func
      |> Beaver.Walker.regions()
      |> Enum.to_list()
      |> hd()
      |> Beaver.Walker.blocks()
      |> Enum.to_list()

    assert [%MLIR.Value{}, %MLIR.Value{}] = block |> Beaver.Walker.arguments() |> Enum.to_list()
    assert "ex.add" in op_names(module)
  end

  test "lifts subtraction and multiplication", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule Math do
          def main() do
            2 * 3 - 1
          end
        end
        """,
        ctx
      )

    assert "ex.mul" in op_names(module)
    assert "ex.sub" in op_names(module)
  end

  test "lifts composite terms with abstract !ex.term type", %{ctx: ctx} do
    module =
      lift!(
        """
        defmodule TermTest do
          def main() do
            {1, [2, 3], %{a: 4}}
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "!ex.term"
    assert rendered =~ "ex.tuple"
    assert rendered =~ "ex.list"
    assert rendered =~ "ex.map"
  end

  test "raises explicitly on unsupported AST", %{ctx: ctx} do
    assert_raise Lift.Error, ~r/unsupported AST/, fn ->
      lift!(
        """
        defmodule M do
          def main() do
            (1 + 2).unknown()
          end
        end
        """,
        ctx
      )
    end
  end

  test "rejects malformed nested module alias parts", %{ctx: ctx} do
    malformed_call = {{:., [], [{:__aliases__, [], [:Foo, 123]}, :bar]}, [], [1]}

    snapshot = %Frontend.Module{
      name: MalformedAlias,
      definitions: [
        %Frontend.Definition{
          kind: :def,
          name: :main,
          arity: 0,
          clauses: [%Frontend.Clause{patterns: [], body_ast: malformed_call}]
        }
      ]
    }

    assert_raise Lift.Error, ~r/unsupported AST.*Foo.*123/s, fn ->
      snapshot |> Lift.module_to_ir(ctx: ctx) |> Beaver.Deferred.resolve(ctx)
    end
  end
end
