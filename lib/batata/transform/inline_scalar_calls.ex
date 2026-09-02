defmodule Batata.Transform.InlineScalarCalls do
  @moduledoc """
  Inlines local calls whose callee stays inside the scalar slice.

  `ex.call` results are typed `!ex.term`, which cannot feed `ex.add`/`ex.sub`/
  `ex.mul`. When a callee's parameters and return value are all `i64`, the
  call is replaced by a clone of the callee body with arguments substituted,
  so the result participates in arithmetic (e.g. `add(1, 2) + 3`). Calls that
  cannot be inlined (self/mutual recursion) are retyped to an i64 result when
  the callee returns i64 (e.g. `count(t)` in a recursive scanner).

  The pass runs bounded bulk-rewrite rounds to a fixpoint so nested scalar
  calls are inlined innermost-first without rescanning the complete IR after
  every individual call. Term-returning callees, unknown callees and arity
  mismatches are left untouched (`ex.call` stays `!ex.term`).
  """

  alias Beaver.Changeset
  alias Beaver.MLIR
  alias Beaver.MLIR.IRMapping
  alias Beaver.MLIR.{IRRewriter, RewriterBase}
  alias Beaver.Walker

  @behaviour Batata.Transform.Pass

  @max_passes 64

  @impl Batata.Transform.Pass
  def run!(%MLIR.Module{} = module) do
    Enum.reduce_while(1..@max_passes, module, fn pass, module ->
      case rewrite_round(module) do
        :unchanged ->
          {:halt, module}

        {:changed, false} ->
          {:halt, module}

        {:changed, true} when pass < @max_passes ->
          {:cont, module}

        {:changed, true} ->
          raise "scalar-call inlining did not converge after #{@max_passes} bulk rounds"
      end
    end)
  end

  defp rewrite_round(module) do
    {funcs, applies, calls} = inventory(module)

    apply_changed? =
      Enum.reduce(applies, false, fn apply, changed? ->
        case retype_apply_action(apply) do
          :ok ->
            retype_apply!(apply)
            true

          :skip ->
            changed?
        end
      end)

    callees = callees(funcs)

    {call_changed?, needs_another_round?} =
      Enum.reduce(calls, {false, false}, fn call, {changed?, another_round?} ->
        case action(call, callees) do
          {:inline, callee} ->
            inline!(call, callee.operation)
            {true, another_round? or callee.rewrite_candidates?}

          {:retype, _callee} ->
            retype!(call)
            {true, another_round?}

          :skip ->
            {changed?, another_round?}
        end
      end)

    if apply_changed? or call_changed?,
      do: {:changed, needs_another_round?},
      else: :unchanged
  end

  # Dynamic anonymous-function application returns the extracted fn's result,
  # which is a scalar i64 in the current slice, so the result can be retyped
  # to participate in arithmetic. Applies whose result only feeds an scf
  # terminator (the scheduler driver's closure dispatch inside `scf.if`) keep
  # their `!ex.term` type so the enclosing select stays type-consistent.
  defp retype_apply_action(apply) do
    cond do
      scalar_typed?(apply) -> :skip
      apply_feeds_terminator?(apply) -> :skip
      true -> :ok
    end
  end

  defp apply_feeds_terminator?(apply) do
    [result] = apply |> Walker.results() |> Enum.to_list()

    result
    |> Walker.uses()
    |> Enum.all?(fn use ->
      use |> MLIR.OpOperand.owner() |> MLIR.Operation.name() == "scf.yield"
    end)
  end

  defp retype_apply!(apply) do
    owner = owner_func(apply)
    args = apply |> Walker.operands() |> Enum.to_list()
    [old_result] = apply |> Walker.results() |> Enum.to_list()

    {:ok, arg_count} = apply |> MLIR.Operation.fetch(:arg_count)
    {:ok, segment_sizes_attr} = apply |> MLIR.Operation.fetch(:operandSegmentSizes)

    new_apply =
      %Changeset{
        name: "ex.apply",
        context: MLIR.context(apply),
        location: MLIR.Operation.location(apply)
      }
      |> Changeset.add_argument(args)
      |> Changeset.add_argument(arg_count: arg_count, operandSegmentSizes: segment_sizes_attr)
      |> Changeset.add_result(MLIR.Type.i64())
      |> MLIR.Operation.create()

    IRRewriter.with_rewriter(owner, fn rewriter ->
      RewriterBase.with_insertion_point(rewriter, {:before, apply}, fn ->
        RewriterBase.insert(rewriter, new_apply)
        [new_result] = new_apply |> Walker.results() |> Enum.to_list()

        replace_scalar_result(rewriter, old_result, new_result, apply)
        RewriterBase.erase_op(rewriter, apply)
      end)
    end)

    :ok
  end

  defp action(call, callees) do
    name = call |> attribute_string("callee")
    arity = call |> attribute_integer("arity")

    resolve_action(call, name, arity, callees)
  end

  # The scheduler driver's calls to the compiled entry must stay opaque:
  # inlining the resumable entry (which the driver re-invokes per slice)
  # would break the process-continuation handoff.
  defp resolve_action(_call, "__batata_entry", _arity, _callees), do: :skip

  defp resolve_action(call, name, arity, callees) do
    case Map.fetch(callees, {name, arity}) do
      {:ok, callee} -> action_for_callee(call, callee)
      :error -> :skip
    end
  end

  defp action_for_callee(call, callee) do
    cond do
      callee.scalar? and scalar_args?(call) -> {:inline, callee}
      callee.scalar_return? and not scalar_typed?(call) -> {:retype, callee}
      true -> :skip
    end
  end

  defp scalar_args?(call) do
    call
    |> Walker.operands()
    |> Enum.all?(&i64_value?/1)
  end

  defp scalar_typed?(call) do
    call
    |> Walker.results()
    |> Enum.to_list()
    |> hd()
    |> MLIR.Value.type()
    |> MLIR.equal?(MLIR.Type.i64())
  end

  # Replaces a call whose callee returns i64 with an i64-typed ex.call, so
  # recursive scalar-returning functions (e.g. binary scanners) can feed
  # arithmetic without being inlined.
  defp retype!(call) do
    owner = owner_func(call)
    args = call |> Walker.operands() |> Enum.to_list()
    name = call |> attribute_string("callee")
    arity = call |> attribute_integer("arity")

    new_call =
      %Changeset{
        name: "ex.call",
        context: MLIR.context(call),
        location: MLIR.Operation.location(call)
      }
      |> Changeset.add_argument(
        args ++
          [
            callee: MLIR.Attribute.string(name),
            arity: MLIR.Attribute.integer(MLIR.Type.i64(), arity),
            operandSegmentSizes: segment_sizes(arg_segment_sizes(length(args)))
          ]
      )
      |> Changeset.add_result(MLIR.Type.i64())
      |> MLIR.Operation.create()

    IRRewriter.with_rewriter(owner, fn rewriter ->
      RewriterBase.with_insertion_point(rewriter, {:before, call}, fn ->
        RewriterBase.insert(rewriter, new_call)
        [old_result] = call |> Walker.results() |> Enum.to_list()
        [new_result] = new_call |> Walker.results() |> Enum.to_list()
        replace_scalar_result(rewriter, old_result, new_result, call)
        RewriterBase.erase_op(rewriter, call)
      end)
    end)

    :ok
  end

  defp segment_sizes(sizes) do
    MLIR.Attribute.dense_array(sizes, Beaver.Native.I32)
  end

  defp arg_segment_sizes(count) do
    unless count <= 8 do
      raise ArgumentError, "calls with more than 8 arguments are unsupported: #{count}"
    end

    List.duplicate(1, count) ++ List.duplicate(0, 8 - count)
  end

  defp inline!(call, callee) do
    owner = owner_func(call)
    args = call |> Walker.operands() |> Enum.to_list()
    block = body_block(callee)
    callee_args = block |> Walker.arguments() |> Enum.to_list()
    terminator = MLIR.CAPI.mlirBlockGetTerminator(block)
    [returned] = terminator |> Walker.operands() |> Enum.to_list()

    IRRewriter.with_rewriter(owner, fn rewriter ->
      inline_at_call(rewriter, call, block, terminator, returned, callee_args, args)
    end)

    :ok
  end

  defp inline_at_call(rewriter, call, block, terminator, returned, callee_args, args) do
    RewriterBase.with_insertion_point(rewriter, {:before, call}, fn ->
      clone_inline_body(rewriter, call, block, terminator, returned, callee_args, args)
    end)
  end

  defp clone_inline_body(rewriter, call, block, terminator, returned, callee_args, args) do
    IRMapping.with_mapping(fn mapping ->
      callee_args
      |> Enum.zip(args)
      |> Enum.each(&map_argument(mapping, &1))

      block
      |> Walker.operations()
      |> Enum.to_list()
      |> Enum.reject(&MLIR.equal?(&1, terminator))
      |> Enum.each(&IRMapping.clone(mapping, &1, rewriter))

      value = IRMapping.lookup_or_default(mapping, returned)
      [call_result] = call |> Walker.results() |> Enum.to_list()
      replace_scalar_result(rewriter, call_result, value, call)
      RewriterBase.erase_op(rewriter, call)
    end)
  end

  defp replace_scalar_result(rewriter, old_result, new_result, anchor) do
    adapters =
      old_result
      |> Walker.uses()
      |> Enum.map(&MLIR.OpOperand.owner/1)
      |> Enum.uniq()

    Enum.each(adapters, fn adapter ->
      case MLIR.Operation.name(adapter) do
        name when name in ["ex.unbox", "ex.to_int"] ->
          replace_passthrough_adapter(rewriter, adapter, new_result)

        "ex.is_integer" ->
          replace_integer_check(rewriter, adapter, anchor)

        name when name in ["ex.term_eq", "ex.term_eq_loose"] ->
          replace_term_equality(rewriter, adapter, old_result, new_result, anchor)

        "ex.integer_compare" ->
          replace_integer_compare(rewriter, adapter, old_result, new_result, anchor)

        _other ->
          :ok
      end
    end)

    RewriterBase.replace(rewriter, old_result, new_result)
  end

  defp replace_passthrough_adapter(rewriter, adapter, new_result) do
    [result] = adapter |> Walker.results() |> Enum.to_list()
    RewriterBase.replace(rewriter, result, new_result)
    RewriterBase.erase_op(rewriter, adapter)
  end

  defp replace_integer_check(rewriter, adapter, anchor) do
    literal =
      create_operation(
        "ex.lit",
        [value: MLIR.Attribute.integer(MLIR.Type.i64(), 1)],
        MLIR.Type.i64(),
        anchor
      )

    RewriterBase.insert(rewriter, literal)
    [literal_result] = literal |> Walker.results() |> Enum.to_list()
    [check_result] = adapter |> Walker.results() |> Enum.to_list()
    RewriterBase.replace(rewriter, check_result, literal_result)
    RewriterBase.erase_op(rewriter, adapter)
  end

  defp replace_term_equality(rewriter, equality, old_result, new_result, anchor) do
    operands =
      equality
      |> Walker.operands()
      |> Enum.map(fn operand ->
        if MLIR.equal?(operand, old_result), do: new_result, else: operand
      end)

    {replacement, boxes} =
      if Enum.all?(operands, &i64_value?/1) do
        {
          create_operation(
            "ex.cmp",
            operands ++ [predicate: MLIR.Attribute.string("eq")],
            MLIR.Type.i64(),
            anchor
          ),
          []
        }
      else
        term_type = MLIR.Value.type(old_result)

        {term_operands, boxes} =
          Enum.map_reduce(operands, [], &box_scalar_operand(&1, &2, term_type, anchor))

        {
          create_operation(
            MLIR.Operation.name(equality),
            term_operands,
            MLIR.Type.i64(),
            anchor
          ),
          boxes
        }
      end

    _insertion_point =
      Enum.reduce(boxes ++ [replacement], {:before, equality}, fn operation, insertion_point ->
        RewriterBase.with_insertion_point(rewriter, insertion_point, fn ->
          RewriterBase.insert(rewriter, operation)
        end)

        {:after, operation}
      end)

    [old_equality_result] = equality |> Walker.results() |> Enum.to_list()
    [new_equality_result] = replacement |> Walker.results() |> Enum.to_list()
    RewriterBase.replace(rewriter, old_equality_result, new_equality_result)
    RewriterBase.erase_op(rewriter, equality)
  end

  defp replace_integer_compare(rewriter, comparison, old_result, new_result, anchor) do
    term_type = MLIR.Value.type(old_result)

    {term_operands, boxes} =
      comparison
      |> Walker.operands()
      |> Enum.map(fn operand ->
        if MLIR.equal?(operand, old_result), do: new_result, else: operand
      end)
      |> Enum.map_reduce([], &box_scalar_operand(&1, &2, term_type, anchor))

    replacement =
      create_operation("ex.integer_compare", term_operands, MLIR.Type.i64(), anchor)

    _insertion_point =
      Enum.reduce(boxes ++ [replacement], {:before, comparison}, fn operation, insertion_point ->
        RewriterBase.with_insertion_point(rewriter, insertion_point, fn ->
          RewriterBase.insert(rewriter, operation)
        end)

        {:after, operation}
      end)

    [old_comparison_result] = comparison |> Walker.results() |> Enum.to_list()
    [new_comparison_result] = replacement |> Walker.results() |> Enum.to_list()
    RewriterBase.replace(rewriter, old_comparison_result, new_comparison_result)
    RewriterBase.erase_op(rewriter, comparison)
  end

  defp box_scalar_operand(operand, boxes, term_type, anchor) do
    if i64_value?(operand) do
      box = create_operation("ex.box", [operand], term_type, anchor)
      box_result = box |> Walker.results() |> Enum.to_list() |> hd()
      {box_result, [box | boxes]}
    else
      {operand, boxes}
    end
  end

  defp create_operation(name, arguments, result_type, anchor) do
    %Changeset{
      name: name,
      context: MLIR.context(anchor),
      location: MLIR.Operation.location(anchor)
    }
    |> Changeset.add_argument(arguments)
    |> Changeset.add_result(result_type)
    |> MLIR.Operation.create()
  end

  defp map_argument(mapping, {from, to}), do: IRMapping.map(mapping, from, to)

  defp i64_value?(value) do
    value
    |> MLIR.Value.type()
    |> MLIR.equal?(MLIR.Type.i64())
  end

  defp callees(funcs) do
    Map.new(funcs, fn func ->
      block = body_block(func)
      arguments = block |> Walker.arguments() |> Enum.to_list()
      operations = block |> Walker.operations() |> Enum.to_list()
      terminator = MLIR.CAPI.mlirBlockGetTerminator(block)
      returned = terminator |> Walker.operands() |> Enum.to_list()
      scalar_return? = match?([_], returned) and Enum.all?(returned, &i64_value?/1)

      # Cloning a control-flow helper duplicates its complete nested region
      # tree. Compute the body classification once per callee per round instead
      # of walking the same body again for every call site.
      straight_line? =
        Enum.all?(operations, fn operation ->
          operation |> Walker.regions() |> Enum.empty?()
        end)

      callee = %{
        operation: func,
        scalar?: straight_line? and scalar_return? and Enum.all?(arguments, &i64_value?/1),
        scalar_return?: scalar_return?,
        rewrite_candidates?:
          Enum.any?(operations, fn operation ->
            MLIR.Operation.name(operation) in ["ex.apply", "ex.call"]
          end)
      }

      {{func |> attribute_string("sym_name"), length(arguments)}, callee}
    end)
  end

  defp body_block(func) do
    func
    |> Walker.regions()
    |> Enum.to_list()
    |> hd()
    |> Walker.blocks()
    |> Enum.to_list()
    |> hd()
  end

  defp owner_func(op) do
    Stream.iterate(op, &MLIR.Operation.parent/1)
    |> Enum.find(fn parent ->
      not MLIR.null?(parent) and MLIR.Operation.name(parent) == "ex.func"
    end)
  end

  # One walk feeds the complete rewrite round. Large qualified compilation
  # units make even a read-only traversal expensive because every operation
  # boundary is a short NIF call; collecting each operation kind separately
  # would multiply that boundary traffic by three per round.
  defp inventory(operation) do
    {_, {funcs, applies, calls}} =
      Walker.postwalk(operation, {[], [], []}, fn
        %MLIR.Operation{} = op, acc ->
          next =
            case MLIR.Operation.name(op) do
              "ex.func" -> put_elem(acc, 0, [op | elem(acc, 0)])
              "ex.apply" -> put_elem(acc, 1, [op | elem(acc, 1)])
              "ex.call" -> put_elem(acc, 2, [op | elem(acc, 2)])
              _other -> acc
            end

          {op, next}

        element, acc ->
          {element, acc}
      end)

    {Enum.reverse(funcs), Enum.reverse(applies), Enum.reverse(calls)}
  end

  defp attribute_string(op, name) do
    case op |> MLIR.Operation.fetch(name) do
      {:ok, attribute} -> attribute |> MLIR.CAPI.mlirStringAttrGetValue() |> MLIR.to_string()
      :error -> nil
    end
  end

  defp attribute_integer(op, name) do
    case op |> MLIR.Operation.fetch(name) do
      {:ok, attribute} ->
        attribute |> MLIR.CAPI.mlirIntegerAttrGetValueInt() |> Beaver.Native.to_term()

      :error ->
        nil
    end
  end
end
