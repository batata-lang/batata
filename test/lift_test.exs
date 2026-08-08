defmodule Batata.LiftTest do
  use Batata.Case, async: true

  alias Batata.{Frontend, Lift}

  defp lift!(source, ctx) do
    source
    |> Frontend.from_source()
    |> Lift.module_to_ir(ctx: ctx)
    |> Beaver.Deferred.create(ctx)
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
             Enum.sort([
               "builtin.module",
               "ex.func",
               "ex.lit",
               "ex.lit",
               "ex.lit",
               "ex.add",
               "ex.add",
               "ex.return"
             ])
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
             Enum.sort([
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
             ])
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
             Enum.sort([
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
             ])
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
             Enum.sort([
               "builtin.module",
               "ex.box",
               "ex.func",
               "ex.list",
               "ex.is_list",
               "ex.return"
             ])
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
             Enum.sort([
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
             ])
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
           |> MLIR.to_string() == "add"

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

  test "raises explicitly on unsupported AST", %{ctx: ctx} do
    assert_raise Lift.Error, ~r/unsupported AST/, fn ->
      lift!(
        """
        defmodule M do
          def main() do
            1.0
          end
        end
        """,
        ctx
      )
    end
  end
end
