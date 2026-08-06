defmodule Batata.Lift do
  @moduledoc """
  Lifts a `Batata.Frontend` module snapshot into `ex` dialect IR.

  The scalar slice supports integer literals, `+`, `=` bindings, local calls,
  and parameterless functions. Bindings lower directly to SSA: `ex.var`/`ex.bind`
  are term-universe bookkeeping and stay out of the typed scalar slice (they are
  erased by `Beaver.MLIR.Dialect.Ex.MaterializeBoundVariables` on the term path).
  Anything outside the slice raises `Batata.Lift.Error` explicitly instead of
  being silently dropped.
  """

  alias Batata.Frontend
  alias Beaver.MLIR
  alias Beaver.MLIR.Dialect.Ex

  defmodule Error do
    @moduledoc "Raised when the frontend encounters an unsupported AST form."
    defexception [:message]
  end

  @doc """
  Builds a `builtin.module` of `ex.func` operations for the snapshot.

  Returns a `Beaver.Deferred`; materialize it with `Beaver.Deferred.create/2`
  against the MLIR context.
  """
  def module_to_ir(%Frontend.Module{} = mod, opts) do
    Beaver.Deferred.from_opts(opts, fn ctx ->
      Beaver.Slang.load(ctx, Ex)

      module = MLIR.Module.create!("module {}", ctx: ctx)
      body = MLIR.CAPI.mlirModuleGetBody(module)

      Enum.each(mod.definitions, fn definition ->
        lift_definition(definition, ctx, body)
      end)

      module
    end)
  end

  defp lift_definition(
         %Frontend.Definition{kind: kind, name: name, arity: arity, clauses: clauses},
         ctx,
         ip
       ) do
    unless kind in [:def, :defp] do
      raise Error, "unsupported definition kind: #{inspect(kind)}"
    end

    if arity != 0 do
      raise Error, "function parameters are unsupported in the scalar slice: #{name}/#{arity}"
    end

    unless length(clauses) == 1 do
      raise Error, "multiple clauses are unsupported in the scalar slice: #{name}/#{arity}"
    end

    [%Frontend.Clause{patterns: [], body_ast: body_ast}] = clauses

    region = MLIR.CAPI.mlirRegionCreate()
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    {return_value, _env} = lift_block(List.wrap(body_ast), ctx, block, %{})
    insert_return(return_value, ctx, block)

    %Beaver.SSA{
      op: "ex.func",
      ip: ip,
      ctx: ctx,
      arguments: [sym_name: MLIR.Attribute.string(to_string(name))],
      results: [],
      filler: fn -> [region] end
    }
    |> MLIR.Operation.create()
  end

  defp lift_block(expressions, ctx, block, env) do
    {values, env} =
      Enum.map_reduce(expressions, env, fn expression, env ->
        lift_expr(expression, ctx, block, env)
      end)

    {List.last(values), env}
  end

  defp lift_expr(integer, ctx, block, env) when is_integer(integer) do
    {
      create_op(
        "ex.lit",
        [value: MLIR.Attribute.integer(MLIR.Type.i64(), integer)],
        [MLIR.Type.i64()],
        ctx,
        block
      ),
      env
    }
  end

  defp lift_expr({:+, _, [left, right]}, ctx, block, env) do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    {
      create_op("ex.add", [left_value, right_value], [MLIR.Type.i64()], ctx, block),
      env
    }
  end

  defp lift_expr({:__block__, _, expressions}, ctx, block, env) do
    lift_block(expressions, ctx, block, env)
  end

  defp lift_expr({:=, _, [{var, _, nil}, rhs]}, ctx, block, env) when is_atom(var) do
    {value, env} = lift_expr(rhs, ctx, block, env)
    {value, Map.put(env, var, value)}
  end

  defp lift_expr({name, _, args}, ctx, block, env) when is_atom(name) and is_list(args) do
    {arg_values, env} =
      Enum.map_reduce(args, env, fn arg, env ->
        lift_expr(arg, ctx, block, env)
      end)

    {
      create_op(
        "ex.call",
        arg_values ++
          [
            callee: MLIR.Attribute.string(to_string(name)),
            arity: MLIR.Attribute.integer(MLIR.Type.i64(), length(args)),
            operandSegmentSizes: segment_sizes([length(args)])
          ],
        [ex_type("dyn", ctx)],
        ctx,
        block
      ),
      env
    }
  end

  defp lift_expr({name, _, nil}, _ctx, _block, env) when is_atom(name) do
    case Map.fetch(env, name) do
      {:ok, value} -> {value, env}
      :error -> raise Error, "unbound variable reference: #{inspect(name)}"
    end
  end

  defp lift_expr(ast, _ctx, _block, _env) do
    raise Error, "unsupported AST in the scalar slice: #{inspect(ast)}"
  end

  defp insert_return(nil, ctx, block) do
    create_op("ex.return", [operandSegmentSizes: segment_sizes([0])], [], ctx, block)
    :ok
  end

  defp insert_return(value, ctx, block) do
    create_op("ex.return", [value, operandSegmentSizes: segment_sizes([1])], [], ctx, block)
    :ok
  end

  defp create_op(op_name, arguments, result_types, ctx, block) do
    operation =
      %Beaver.SSA{
        op: op_name,
        ip: block,
        ctx: ctx,
        arguments: arguments,
        results: result_types,
        loc: MLIR.Location.unknown()
      }
      |> MLIR.Operation.create()

    case result_types do
      [] -> operation
      [_] -> operation |> MLIR.Operation.results() |> Enum.to_list() |> hd()
      _ -> operation |> MLIR.Operation.results() |> Enum.to_list()
    end
  end

  defp ex_type(name, ctx) do
    Beaver.Slang.create_constrained_element(:type, "ex", name, [], ctx: ctx)
    |> Beaver.Deferred.create(ctx)
  end

  defp segment_sizes(sizes) do
    MLIR.Attribute.array(Enum.map(sizes, &MLIR.Attribute.integer(MLIR.Type.i32(), &1)))
  end
end
