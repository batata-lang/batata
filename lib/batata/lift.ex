defmodule Batata.Lift do
  @moduledoc """
  Lifts a `Batata.Frontend` module snapshot into `ex` dialect IR.

  The scalar slice supports integer literals, `+`/`-`/`*`, `=` bindings, local
  calls, comparisons (`==`/`!=`/`<`/`<=`/`>`/`>=`), `case` with integer literal
  or catch-all patterns and optional guards, and functions with integer
  parameters. Multi-clause functions (single argument) dispatch on the
  argument with `ex.case`; the final clause must be a catch-all. The term
  slice adds tuple, list, map and binary literals plus the `Kernel` term
  predicates
  (`is_atom`/`is_binary`/`is_list`/`is_tuple`/`is_map`/`is_integer`); they
  lift to the `ex.tuple`/`ex.list`/`ex.map`/`ex.binary`/`ex.is_*` ops and are
  lowered through the Zig term runtime ABI. Bindings lower directly to SSA:
  `ex.var`/`ex.bind` are term-universe bookkeeping and stay out of the typed
  scalar slice (they are erased by
  `Beaver.MLIR.Dialect.Ex.MaterializeBoundVariables` on the term path). Anything
  outside the slice raises `Batata.Lift.Error` explicitly instead of being
  silently dropped.
  """

  alias Batata.Frontend
  alias Batata.Transform.PatternPlan
  alias Beaver.MLIR
  alias Beaver.MLIR.Dialect.Ex
  alias Beaver.Walker

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
      unless ex_dialect_loaded?(ctx) do
        Beaver.Slang.load(ctx, Ex)
      end

      module = MLIR.Module.create!("module {}", ctx: ctx)
      body = MLIR.CAPI.mlirModuleGetBody(module)

      mod.definitions
      |> Enum.group_by(&{&1.name, &1.arity})
      |> Enum.each(fn {_key, definitions} ->
        lift_definitions(definitions, ctx, body)
      end)

      module
    end)
  end

  # `Beaver.Slang.load/2` registers the IRDL ops in the context and is not
  # idempotent: loading the same dialect twice crashes MLIR with an operation
  # registration assertion. Skip it when the ex dialect is already present.
  defp ex_dialect_loaded?(ctx) do
    ctx
    |> MLIR.CAPI.mlirContextIsRegisteredOperation(MLIR.StringRef.create("ex.box"))
    |> Beaver.Native.to_term()
  end

  defp lift_definition(
         %Frontend.Definition{kind: kind, name: name, arity: arity, clauses: clauses},
         ctx,
         ip
       ) do
    unless kind in [:def, :defp] do
      raise Error, "unsupported definition kind: #{inspect(kind)}"
    end

    unless length(clauses) == 1 do
      raise Error, "multiple clauses are unsupported in the scalar slice: #{name}/#{arity}"
    end

    [%Frontend.Clause{patterns: patterns, body_ast: body_ast}] = clauses

    region = MLIR.CAPI.mlirRegionCreate()
    arg_types = List.duplicate(integer_type(ctx), length(patterns))
    arg_locs = List.duplicate(MLIR.Location.unknown(ctx: ctx), length(patterns))
    block = MLIR.Block.create(arg_types, arg_locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    env =
      block
      |> Walker.arguments()
      |> Enum.to_list()
      |> Enum.zip(patterns)
      |> Enum.reduce(%{}, fn {value, pattern}, env ->
        Map.put(env, param_name(pattern), value)
      end)

    {return_value, _env} = lift_block(List.wrap(body_ast), ctx, block, env)
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

  defp lift_definitions([definition], ctx, ip) do
    lift_definition(definition, ctx, ip)
  end

  # Multiple `def` forms with the same name/arity become one ex.func whose
  # body dispatches on the argument with ex.case, matching each clause's
  # pattern (the cursor-loop foundation for recursive scanners). M2 requires
  # a single argument and a final catch-all clause.
  defp lift_definitions(definitions, ctx, ip) do
    %Frontend.Definition{kind: kind, name: name, arity: arity} = hd(definitions)

    unless kind in [:def, :defp] do
      raise Error, "unsupported definition kind: #{inspect(kind)}"
    end

    unless arity == 1 do
      raise Error,
            "multi-clause functions with multiple arguments are unsupported: #{name}/#{arity}"
    end

    clauses = Enum.flat_map(definitions, & &1.clauses)

    region = MLIR.CAPI.mlirRegionCreate()

    # The argument is a scalar word (like single-clause functions); the term
    # path re-types it with ex.to_word when term reads are involved.
    arg_locs = [MLIR.Location.unknown(ctx: ctx)]
    block = MLIR.Block.create([integer_type(ctx)], arg_locs)
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [arg] = block |> Walker.arguments() |> Enum.to_list()

    clause_asts =
      Enum.map(clauses, fn %Frontend.Clause{patterns: [pattern], body_ast: body_ast} ->
        {:->, [], [[pattern], body_ast]}
      end)

    return_value =
      lift_case(clause_asts, arg, %{}, ctx, block, relax_types: true, box_scrutinee: false)

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

  defp lift_expr({:-, _, [left, right]}, ctx, block, env) do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    {
      create_op("ex.sub", [left_value, right_value], [MLIR.Type.i64()], ctx, block),
      env
    }
  end

  defp lift_expr({:*, _, [left, right]}, ctx, block, env) do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    {
      create_op("ex.mul", [left_value, right_value], [MLIR.Type.i64()], ctx, block),
      env
    }
  end

  defp lift_expr(binary, ctx, block, env) when is_binary(binary) do
    {values, env} =
      binary
      |> :binary.bin_to_list()
      |> Enum.map_reduce(env, fn byte, env ->
        {value, env} = lift_expr(byte, ctx, block, env)
        {box_term(value, ctx, block), env}
      end)

    {create_term_op("ex.binary", values, ctx, block), env}
  end

  defp lift_expr([], ctx, block, env) do
    {create_term_op("ex.list", [], ctx, block), env}
  end

  defp lift_expr(elements, ctx, block, env) when is_list(elements) do
    {values, env} = lift_operands_boxed(elements, ctx, block, env)
    {create_term_op("ex.list", values, ctx, block), env}
  end

  defp lift_expr({:%{}, _, entries}, ctx, block, env) do
    {values, env} = lift_map_entries(entries, ctx, block, env)
    {create_term_op("ex.map", values, ctx, block), env}
  end

  defp lift_expr({:<<>>, _, segments}, ctx, block, env) do
    {values, env} = lift_operands_boxed(segments, ctx, block, env)
    {create_term_op("ex.binary", values, ctx, block), env}
  end

  defp lift_expr({name, _, [arg]}, ctx, block, env)
       when name in [:is_atom, :is_binary, :is_list, :is_tuple, :is_map, :is_integer] do
    {value, env} = lift_expr(arg, ctx, block, env)
    {create_op("ex.#{name}", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block), env}
  end

  defp lift_expr({op, _, [left, right]}, ctx, block, env)
       when op in [:==, :!=, :<, :<=, :>, :>=] do
    {left_value, env} = lift_expr(left, ctx, block, env)
    {right_value, env} = lift_expr(right, ctx, block, env)

    {
      create_op(
        "ex.cmp",
        [left_value, right_value, predicate: MLIR.Attribute.string(cmp_predicate(op))],
        [MLIR.Type.i64()],
        ctx,
        block
      ),
      env
    }
  end

  defp lift_expr({:case, _, [scrutinee_ast, [do: clauses]]}, ctx, block, env) do
    {scrutinee, env} = lift_expr(scrutinee_ast, ctx, block, env)
    {lift_case(clauses, scrutinee, env, ctx, block), env}
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

  # Tuple literals: calls, operators and variables are 3-tuples in the AST and
  # are handled above, so every other tuple shape is a literal tuple.
  defp lift_expr(tuple, ctx, block, env) when is_tuple(tuple) and tuple_size(tuple) != 3 do
    lift_tuple_literal(tuple, ctx, block, env)
  end

  defp lift_expr({a, b, c}, ctx, block, env)
       when not (is_atom(a) and is_list(b) and is_list(c)) do
    lift_tuple_literal({a, b, c}, ctx, block, env)
  end

  defp lift_expr(ast, _ctx, _block, _env) do
    raise Error, "unsupported AST in the current slice: #{inspect(ast)}"
  end

  defp lift_tuple_literal(tuple, ctx, block, env) do
    {values, env} = lift_operands_boxed(Tuple.to_list(tuple), ctx, block, env)
    {create_term_op("ex.tuple", values, ctx, block), env}
  end

  defp cmp_predicate(:==), do: "eq"
  defp cmp_predicate(:!=), do: "ne"
  defp cmp_predicate(:<), do: "slt"
  defp cmp_predicate(:<=), do: "sle"
  defp cmp_predicate(:>), do: "sgt"
  defp cmp_predicate(:>=), do: "sge"

  defp lift_case(clauses, scrutinee, env, ctx, block, opts \\ []) do
    if Enum.any?(clauses, &(clause_pattern(&1) |> term_pattern?())) do
      lift_term_case(clauses, scrutinee, env, ctx, block, opts)
    else
      lift_scalar_case(clauses, scrutinee, env, ctx, block, opts)
    end
  end

  defp lift_scalar_case(clauses, scrutinee, env, ctx, block, opts) do
    parsed = Enum.map(clauses, &parse_clause/1)

    unless parsed |> List.last() |> Map.fetch!(:patterns) == [] do
      raise Error, "case requires a final catch-all clause"
    end

    guards =
      Enum.map(parsed, fn clause ->
        case clause.guard do
          nil -> nil
          guard_ast -> lift_guard(guard_ast, clause.vars, scrutinee, env, ctx, block)
        end
      end)

    region = MLIR.CAPI.mlirRegionCreate()

    yield_types =
      parsed
      |> Enum.zip(guards)
      |> Enum.map(fn {clause, guard} ->
        add_clause_block(clause, guard, scrutinee, env, ctx, region)
      end)

    [first_type | rest_types] = yield_types

    unless Keyword.get(opts, :relax_types, false) or
             Enum.all?(rest_types, &MLIR.equal?(first_type, &1)) do
      raise Error, "case clauses must yield the same type"
    end

    result_type = first_type

    case_op =
      %Beaver.SSA{
        op: "ex.case",
        ip: block,
        ctx: ctx,
        arguments: [scrutinee, operandSegmentSizes: segment_sizes([1])],
        results: [result_type],
        loc: MLIR.Location.unknown(),
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()

    case_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
  end

  defp lift_term_case(clauses, scrutinee, env, ctx, block, opts) do
    parsed = Enum.map(clauses, &parse_term_clause/1)

    unless match?(
             {name, _, nil} when is_atom(name),
             parsed |> List.last() |> Map.fetch!(:pattern)
           ) do
      raise Error, "case requires a final catch-all clause"
    end

    # term reads require a tagged word, so box the scrutinee once up front
    # (a no-op for values that already are terms). Multi-clause function
    # arguments already carry the tagged word, so they are re-typed with
    # ex.to_word instead (pure passthrough, no re-tagging).
    scrutinee =
      if Keyword.get(opts, :box_scrutinee, true) do
        box_term(scrutinee, ctx, block)
      else
        create_op("ex.to_word", [scrutinee], [ex_type("dyn", ctx)], ctx, block)
      end

    {guards, bindss} =
      parsed
      |> Enum.map(fn clause ->
        {match_cond, binds} = build_match(clause.pattern, scrutinee, ctx, block)

        cond =
          case clause.guard do
            nil ->
              match_cond

            guard_ast ->
              guard_cond = lift_term_guard(guard_ast, binds, env, ctx, block)
              combine([match_cond, guard_cond], ctx, block)
          end

        {cond, binds}
      end)
      |> Enum.unzip()

    region = MLIR.CAPI.mlirRegionCreate()

    yield_types =
      parsed
      |> Enum.zip(guards)
      |> Enum.zip(bindss)
      |> Enum.map(fn {{clause, guard}, binds} ->
        add_term_clause_block(clause, guard, binds, env, ctx, region)
      end)

    [first_type | rest_types] = yield_types

    unless Keyword.get(opts, :relax_types, false) or
             Enum.all?(rest_types, &MLIR.equal?(first_type, &1)) do
      raise Error, "case clauses must yield the same type"
    end

    case_op =
      %Beaver.SSA{
        op: "ex.case",
        ip: block,
        ctx: ctx,
        arguments: [scrutinee, operandSegmentSizes: segment_sizes([1])],
        results: [first_type],
        loc: MLIR.Location.unknown(),
        filler: fn -> [region] end
      }
      |> MLIR.Operation.create()

    case_op |> MLIR.Operation.results() |> Enum.to_list() |> hd()
  end

  # The match condition and the bound values of one term pattern are computed
  # eagerly before `ex.case`: predicates and reads are pure and safe on the
  # wrong term kind (reads return nil), so a non-matching clause's eager
  # values are simply unused. The combined condition becomes the clause guard.
  defp build_match(pattern, value, ctx, block) do
    do_build_match(pattern, value, ctx, block)
  end

  defp do_build_match({name, _, nil}, value, _ctx, _block) when is_atom(name) do
    if name == :_ do
      {nil, []}
    else
      {nil, [{name, value}]}
    end
  end

  defp do_build_match(integer, value, ctx, block) when is_integer(integer) do
    lit =
      create_op(
        "ex.lit",
        [value: MLIR.Attribute.integer(MLIR.Type.i64(), integer)],
        [MLIR.Type.i64()],
        ctx,
        block
      )

    boxed = box_term(lit, ctx, block)
    {create_op("ex.term_eq", [value, boxed], [MLIR.Type.i64()], ctx, block), []}
  end

  defp do_build_match(tuple, value, ctx, block) when is_tuple(tuple) and tuple_size(tuple) != 3 do
    build_tuple_match(Tuple.to_list(tuple), value, ctx, block)
  end

  defp do_build_match({a, b, c}, value, ctx, block)
       when not (is_atom(a) and is_list(b) and is_list(c)) do
    build_tuple_match([a, b, c], value, ctx, block)
  end

  defp do_build_match({:{}, _, elements}, value, ctx, block) do
    build_tuple_match(elements, value, ctx, block)
  end

  defp do_build_match({:<<>>, _, segments}, value, ctx, block) do
    build_binary_match(segments, value, ctx, block)
  end

  defp do_build_match([], value, ctx, block) do
    cond_list =
      create_op("ex.is_list", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    cond_len =
      cmp(
        create_op("ex.list_length", [value], [MLIR.Type.i64()], ctx, block),
        0,
        "eq",
        ctx,
        block
      )

    {combine([cond_list, cond_len], ctx, block), []}
  end

  defp do_build_match([{:|, _, [head, tail]}], value, ctx, block) do
    cond_list =
      create_op("ex.is_list", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    cond_nonempty =
      cmp(
        create_op("ex.list_length", [value], [MLIR.Type.i64()], ctx, block),
        0,
        "ne",
        ctx,
        block
      )

    head_value = create_op("ex.list_head", [value], [ex_type("dyn", ctx)], ctx, block)
    tail_value = create_op("ex.list_tail", [value], [ex_type("dyn", ctx)], ctx, block)
    {head_cond, head_binds} = do_build_match(head, head_value, ctx, block)
    {tail_cond, tail_binds} = do_build_match(tail, tail_value, ctx, block)

    {combine([cond_list, cond_nonempty, head_cond, tail_cond], ctx, block),
     head_binds ++ tail_binds}
  end

  defp do_build_match(elements, value, ctx, block) when is_list(elements) do
    cond_list =
      create_op("ex.is_list", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    cond_len =
      cmp(
        create_op("ex.list_length", [value], [MLIR.Type.i64()], ctx, block),
        length(elements),
        "eq",
        ctx,
        block
      )

    {elem_conds, binds} = list_elements_match(elements, value, ctx, block, [])
    {combine([cond_list, cond_len | elem_conds], ctx, block), binds}
  end

  defp do_build_match(other, _value, _ctx, _block) do
    raise Error, "unsupported term pattern: #{inspect(other)}"
  end

  defp build_tuple_match(elements, value, ctx, block) do
    cond_tuple =
      create_op("ex.is_tuple", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    cond_len =
      cmp(
        create_op("ex.tuple_length", [value], [MLIR.Type.i64()], ctx, block),
        length(elements),
        "eq",
        ctx,
        block
      )

    {elem_conds, binds} =
      elements
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {element, index}, binds ->
        element_value =
          create_op(
            "ex.tuple_get",
            [value, lit(index, ctx, block)],
            [ex_type("dyn", ctx)],
            ctx,
            block
          )

        {cond, element_binds} = do_build_match(element, element_value, ctx, block)
        {cond, element_binds ++ binds}
      end)

    {combine([cond_tuple, cond_len | elem_conds], ctx, block), Enum.reverse(binds)}
  end

  defp list_elements_match([], _value, _ctx, _block, binds), do: {[], binds}

  defp list_elements_match([element | rest], value, ctx, block, binds) do
    head_value = create_op("ex.list_head", [value], [ex_type("dyn", ctx)], ctx, block)
    tail_value = create_op("ex.list_tail", [value], [ex_type("dyn", ctx)], ctx, block)
    {head_cond, head_binds} = do_build_match(element, head_value, ctx, block)
    {tail_conds, tail_binds} = list_elements_match(rest, tail_value, ctx, block, binds)
    {[head_cond | tail_conds], head_binds ++ tail_binds}
  end

  defp build_binary_match(segments, value, ctx, block) do
    {segs, rest} = parse_binary_segments(segments)

    cond_bin =
      create_op("ex.is_binary", [box_term(value, ctx, block)], [MLIR.Type.i64()], ctx, block)

    {conds, binds, offset} =
      Enum.reduce(segs, {[], [], lit(0, ctx, block)}, fn seg, {conds, binds, offset} ->
        case seg do
          {:byte, pat} ->
            byte_value =
              create_op(
                "ex.binary_get",
                [value, offset],
                [ex_type("dyn", ctx)],
                ctx,
                block
              )

            {cond, pat_binds} = do_build_match(pat, byte_value, ctx, block)

            next =
              create_op("ex.add", [offset, lit(1, ctx, block)], [MLIR.Type.i64()], ctx, block)

            {[cond | conds], pat_binds ++ binds, next}

          {:utf8, pat} ->
            width =
              create_op("ex.binary_utf8_width", [value, offset], [MLIR.Type.i64()], ctx, block)

            codepoint =
              create_op("ex.binary_utf8_get", [value, offset], [ex_type("dyn", ctx)], ctx, block)

            cond_w = cmp(width, 0, "ne", ctx, block)
            {pat_cond, pat_binds} = do_build_match(pat, codepoint, ctx, block)
            next = create_op("ex.add", [offset, width], [MLIR.Type.i64()], ctx, block)
            {[cond_w, pat_cond | conds], pat_binds ++ binds, next}
        end
      end)

    {rest_cond, rest_binds} =
      case rest do
        nil ->
          {nil, []}

        rest_pat ->
          rest_value =
            create_op("ex.binary_slice", [value, offset], [ex_type("dyn", ctx)], ctx, block)

          do_build_match(rest_pat, rest_value, ctx, block)
      end

    cond_len =
      cmp(
        create_op("ex.binary_length", [value], [MLIR.Type.i64()], ctx, block),
        offset,
        if(rest == nil, do: "eq", else: "sge"),
        ctx,
        block
      )

    {combine([cond_bin, cond_len | Enum.reverse(conds) ++ [rest_cond]], ctx, block),
     Enum.reverse(binds) ++ rest_binds}
  end

  defp parse_binary_segments(segments) do
    {segs, rest} =
      Enum.split_while(segments, &(not match?({:"::", _, [_, {:binary, _, nil}]}, &1)))

    case rest do
      [] ->
        {Enum.map(segs, &binary_segment!/1), nil}

      [{:"::", _, [rest_pat, {:binary, _, nil}]}] ->
        {Enum.map(segs, &binary_segment!/1), rest_pat}

      _ ->
        raise Error, "binary rest segment must be the last segment: #{inspect(segments)}"
    end
  end

  defp binary_segment!({:"::", _, [pat, 8]}), do: {:byte, pat}
  defp binary_segment!({:"::", _, [pat, {:utf8, _, nil}]}), do: {:utf8, pat}
  defp binary_segment!(pat) when is_integer(pat), do: {:byte, pat}
  defp binary_segment!({name, _, nil} = pat) when is_atom(name), do: {:byte, pat}

  defp binary_segment!(segment) do
    raise Error, "unsupported binary segment: #{inspect(segment)}"
  end

  defp add_term_clause_block(clause, guard, binds, env, ctx, region) do
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    clause_args = if guard, do: [guard], else: []
    create_op("ex.clause", clause_args ++ [patterns: pattern_attr([])], [], ctx, block)

    clause_env = Enum.reduce(binds, env, fn {var, value}, acc -> Map.put(acc, var, value) end)
    {value, _env} = lift_block(List.wrap(clause.body), ctx, block, clause_env)
    create_op("ex.yield", [value, operandSegmentSizes: segment_sizes([1])], [], ctx, block)
    MLIR.Value.type(value)
  end

  defp combine(conds, ctx, block) do
    conds
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        nil

      [single] ->
        single

      many ->
        Enum.reduce(many, fn cond, acc ->
          create_op("arith.andi", [acc, cond], [MLIR.Type.i64()], ctx, block)
        end)
    end
  end

  # Term-pattern guards are evaluated eagerly against the (nil-safe) bound
  # values, so they must be composed of term-safe predicates only: `is_*`
  # calls on bound or outer variables. Comparisons and arithmetic on terms
  # are rejected explicitly.
  defp lift_term_guard(guard_ast, binds, env, ctx, block) do
    unless supported_term_guard?(guard_ast) do
      raise Error,
            "unsupported guard on term pattern (only is_* predicates on bound or outer variables): " <>
              inspect(guard_ast)
    end

    guard_env = Map.merge(env, Map.new(binds))
    {value, _env} = lift_expr(guard_ast, ctx, block, guard_env)
    value
  end

  defp supported_term_guard?({predicate, _, [var_ast]})
       when predicate in [:is_integer, :is_atom, :is_binary, :is_list, :is_tuple, :is_map] do
    match?({name, _, nil} when is_atom(name), var_ast)
  end

  defp supported_term_guard?(_guard_ast), do: false

  defp lit(value, ctx, block) do
    create_op(
      "ex.lit",
      [value: MLIR.Attribute.integer(MLIR.Type.i64(), value)],
      [MLIR.Type.i64()],
      ctx,
      block
    )
  end

  defp cmp(left, right, predicate, ctx, block) do
    right = if is_integer(right), do: lit(right, ctx, block), else: right

    create_op(
      "ex.cmp",
      [left, right, predicate: MLIR.Attribute.string(predicate)],
      [MLIR.Type.i64()],
      ctx,
      block
    )
  end

  defp clause_pattern({:->, _, [args, _body]}) when is_list(args) do
    case args do
      [{:when, _, [pattern, _guard]}] -> pattern
      [pattern] -> pattern
      _ -> raise Error, "case clauses with multiple patterns are unsupported: #{inspect(args)}"
    end
  end

  defp parse_term_clause({:->, _, [args, body]}) when is_list(args) do
    {pattern, guard} =
      case args do
        [{:when, _, [pattern, guard]}] -> {pattern, guard}
        [pattern] -> {pattern, nil}
        _ -> raise Error, "case clauses with multiple patterns are unsupported: #{inspect(args)}"
      end

    %{pattern: pattern, guard: guard, body: body}
  end

  defp term_pattern?(pattern) do
    pattern
    |> PatternPlan.lower_pattern()
    |> Enum.any?(&(&1.op in [:tuple, :list_exact, :list_cons, :binary]))
  end

  defp parse_clause({:->, _, [args, body]}) when is_list(args) do
    {pattern, guard} =
      case args do
        [{:when, _, [pattern, guard]}] -> {pattern, guard}
        [pattern] -> {pattern, nil}
        _ -> raise Error, "case clauses with multiple patterns are unsupported: #{inspect(args)}"
      end

    {patterns, vars} = parse_pattern(pattern)
    %{pattern: pattern, patterns: patterns, vars: vars, guard: guard, body: body}
  end

  defp parse_pattern(integer) when is_integer(integer), do: {[integer], []}

  defp parse_pattern({name, _, nil}) when is_atom(name) do
    if name == :_ do
      {[], []}
    else
      {[], [name]}
    end
  end

  defp parse_pattern(pattern) do
    raise Error, "unsupported case pattern: #{inspect(pattern)}"
  end

  defp lift_guard(guard_ast, vars, scrutinee, env, ctx, block) do
    guard_env = Enum.reduce(vars, env, fn var, acc -> Map.put(acc, var, scrutinee) end)
    {value, _env} = lift_expr(guard_ast, ctx, block, guard_env)
    value
  end

  defp add_clause_block(clause, guard, scrutinee, env, ctx, region) do
    block = MLIR.Block.create([], [])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)

    clause_env = Enum.reduce(clause.vars, env, fn var, acc -> Map.put(acc, var, scrutinee) end)

    clause_attrs = [patterns: pattern_attr(clause.patterns)]
    clause_args = if guard, do: [guard], else: []
    create_op("ex.clause", clause_args ++ clause_attrs, [], ctx, block)

    {value, _env} = lift_block(List.wrap(clause.body), ctx, block, clause_env)
    create_op("ex.yield", [value, operandSegmentSizes: segment_sizes([1])], [], ctx, block)
    MLIR.Value.type(value)
  end

  defp pattern_attr(patterns) do
    MLIR.Attribute.dense_array(patterns, Beaver.Native.I64)
  end

  # Values crossing into a term-universe op are boxed with `ex.box`; the
  # conversion turns the box into a tagged word (and is a no-op for values
  # that already are terms).
  defp lift_operands_boxed(args, ctx, block, env) do
    Enum.map_reduce(args, env, fn arg, env ->
      {value, env} = lift_expr(arg, ctx, block, env)
      {box_term(value, ctx, block), env}
    end)
  end

  defp box_term(value, ctx, block) do
    create_op("ex.box", [value], [ex_type("dyn", ctx)], ctx, block)
  end

  defp lift_map_entries(entries, ctx, block, env) do
    Enum.flat_map_reduce(entries, env, fn entry, env ->
      case entry do
        {key, _value} when is_atom(key) ->
          raise Error,
                "atom-keyed map entries are unsupported in the term slice: #{inspect(entry)}"

        {key, value} ->
          {key_value, env} = lift_expr(key, ctx, block, env)
          {value_value, env} = lift_expr(value, ctx, block, env)
          {[box_term(key_value, ctx, block), box_term(value_value, ctx, block)], env}

        other ->
          {value, env} = lift_expr(other, ctx, block, env)
          {[box_term(value, ctx, block)], env}
      end
    end)
  end

  defp create_term_op(op_name, args, ctx, block) do
    create_op(
      op_name,
      args ++ [operandSegmentSizes: segment_sizes([length(args)])],
      [ex_type("dyn", ctx)],
      ctx,
      block
    )
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

  defp param_name({name, _, nil}) when is_atom(name), do: name
  defp param_name(pattern), do: raise(Error, "unsupported parameter pattern: #{inspect(pattern)}")

  defp integer_type(ctx), do: MLIR.Type.integer(64, ctx: ctx)

  defp ex_type(name, ctx) do
    Beaver.Slang.create_constrained_element(:type, "ex", name, [], ctx: ctx)
    |> Beaver.Deferred.create(ctx)
  end

  defp segment_sizes(sizes) do
    MLIR.Attribute.array(Enum.map(sizes, &MLIR.Attribute.integer(MLIR.Type.i32(), &1)))
  end
end
