defmodule Batata.LiftTest do
  use ExUnit.Case, async: true

  alias Batata.{Frontend, Lift}
  alias Beaver.MLIR

  defp with_ctx(fun) do
    ctx = MLIR.Context.create()

    try do
      fun.(ctx)
    after
      MLIR.Context.destroy(ctx)
    end
  end

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

  test "lifts literals, bindings and addition into ex IR" do
    with_ctx(fn ctx ->
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
    end)
  end

  test "lifts local calls with callee and arity attributes" do
    with_ctx(fn ctx ->
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
    end)
  end

  test "raises explicitly on unsupported AST" do
    with_ctx(fn ctx ->
      assert_raise Lift.Error, ~r/unsupported AST/, fn ->
        lift!(
          """
          defmodule M do
            def main() do
              "string"
            end
          end
          """,
          ctx
        )
      end
    end)
  end
end
