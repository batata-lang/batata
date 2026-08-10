defmodule Batata.Transform.InlineScalarCalls do
  @moduledoc """
  Inlines local calls whose callee stays inside the scalar slice.

  `ex.call` results are typed `!ex.dyn`, which cannot feed `ex.add`/`ex.sub`/
  `ex.mul`. When a callee's parameters and return value are all `i64`, the
  call is replaced by a clone of the callee body with arguments substituted,
  so the result participates in arithmetic (e.g. `add(1, 2) + 3`). Calls that
  cannot be inlined (self/mutual recursion) are retyped to an i64 result when
  the callee returns i64 (e.g. `count(t)` in a recursive scanner).

  The pass runs to a fixpoint so nested scalar calls are inlined
  innermost-first. Term-returning callees, unknown callees and arity
  mismatches are left untouched (`ex.call` stays `!ex.dyn`).
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
    _status =
      Enum.reduce_while(1..@max_passes, :unchanged, fn _, _ ->
        case inline_once(module) do
          :changed -> {:cont, :changed}
          :unchanged -> {:halt, :unchanged}
        end
      end)

    module
  end

  defp inline_once(module) do
    callees = callees(module)

    case module |> ops_of("ex.apply") |> Enum.find(&(retype_apply_action(&1) == :ok)) do
      nil ->
        inline_call_once(module, callees)

      apply ->
        retype_apply!(apply)
        :changed
    end
  end

  defp inline_call_once(module, callees) do
    case module |> ops_of("ex.call") |> Enum.find(&(action(&1, callees) != :skip)) do
      nil ->
        :unchanged

      call ->
        case action(call, callees) do
          {:inline, callee} -> inline!(call, callee)
          {:retype, _callee} -> retype!(call)
        end

        :changed
    end
  end

  # Dynamic anonymous-function application returns the extracted fn's result,
  # which is a scalar i64 in the current slice, so the result can be retyped
  # to participate in arithmetic. Applies whose result only feeds an scf
  # terminator (the scheduler driver's closure dispatch inside `scf.if`) keep
  # their `!ex.dyn` type so the enclosing select stays type-consistent.
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
        [old_result] = apply |> Walker.results() |> Enum.to_list()
        [new_result] = new_apply |> Walker.results() |> Enum.to_list()
        RewriterBase.replace(rewriter, old_result, new_result)
        RewriterBase.erase_op(rewriter, apply)
      end)
    end)

    :ok
  end

  defp action(call, callees) do
    name = call |> attribute_string("callee")
    arity = call |> attribute_integer("arity")

    # The scheduler driver's calls to the compiled entry must stay opaque:
    # inlining the resumable entry (which the driver re-invokes per slice)
    # would break the process-continuation handoff.
    if name == "__batata_entry" do
      :skip
    else
      case Map.fetch(callees, {name, arity}) do
        {:ok, callee} ->
          cond do
            scalar?(callee) and scalar_args?(call) -> {:inline, callee}
            scalar_return?(callee) and not scalar_typed?(call) -> {:retype, callee}
            true -> :skip
          end

        :error ->
          :skip
      end
    end
  end

  defp scalar_args?(call) do
    call
    |> Walker.operands()
    |> Enum.all?(&(MLIR.to_string(MLIR.Value.type(&1)) == "i64"))
  end

  defp scalar_return?(callee) do
    terminator = callee |> body_block() |> MLIR.CAPI.mlirBlockGetTerminator()

    case terminator |> Walker.operands() |> Enum.to_list() do
      [value] -> MLIR.to_string(MLIR.Value.type(value)) == "i64"
      _ -> false
    end
  end

  defp scalar_typed?(call) do
    call
    |> Walker.results()
    |> Enum.to_list()
    |> hd()
    |> MLIR.Value.type()
    |> MLIR.to_string() == "i64"
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
        RewriterBase.replace(rewriter, old_result, new_result)
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
      RewriterBase.with_insertion_point(rewriter, {:before, call}, fn ->
        IRMapping.with_mapping(fn mapping ->
          Enum.zip(callee_args, args)
          |> Enum.each(fn {from, to} -> IRMapping.map(mapping, from, to) end)

          block
          |> Walker.operations()
          |> Enum.to_list()
          |> Enum.reject(&MLIR.equal?(&1, terminator))
          |> Enum.each(&IRMapping.clone(mapping, &1, rewriter))

          value = IRMapping.lookup_or_default(mapping, returned)
          [call_result] = call |> Walker.results() |> Enum.to_list()
          RewriterBase.replace(rewriter, call_result, value)
          RewriterBase.erase_op(rewriter, call)
        end)
      end)
    end)

    :ok
  end

  # A callee is in the scalar slice when every parameter and the return value
  # are i64.
  defp scalar?(callee) do
    block = body_block(callee)
    terminator = MLIR.CAPI.mlirBlockGetTerminator(block)

    Enum.all?(
      block |> Walker.arguments() |> Enum.to_list(),
      &(MLIR.to_string(MLIR.Value.type(&1)) == "i64")
    ) and
      match?([_], terminator |> Walker.operands() |> Enum.to_list()) and
      terminator
      |> Walker.operands()
      |> Enum.to_list()
      |> Enum.all?(&(MLIR.to_string(MLIR.Value.type(&1)) == "i64"))
  end

  defp callees(module) do
    module
    |> ops_of("ex.func")
    |> Map.new(fn func ->
      block = body_block(func)
      arity = block |> Walker.arguments() |> Enum.to_list() |> length()
      {{func |> attribute_string("sym_name"), arity}, func}
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

  defp ops_of(operation, name) do
    {_, ops} =
      Walker.postwalk(operation, [], fn
        %MLIR.Operation{} = op, acc ->
          {op, if(MLIR.Operation.name(op) == name, do: [op | acc], else: acc)}

        element, acc ->
          {element, acc}
      end)

    Enum.reverse(ops)
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
