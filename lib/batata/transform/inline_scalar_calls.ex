defmodule Batata.Transform.InlineScalarCalls do
  @moduledoc """
  Inlines local calls whose callee stays inside the scalar slice.

  `ex.call` results are typed `!ex.dyn`, which cannot feed `ex.add`/`ex.sub`/
  `ex.mul`. When a callee's parameters and return value are all `i64`, the
  call is replaced by a clone of the callee body with arguments substituted,
  so the result participates in arithmetic (e.g. `add(1, 2) + 3`).

  The pass runs to a fixpoint so nested scalar calls are inlined
  innermost-first. Non-scalar callees, self-recursion, unknown callees and
  arity mismatches are left untouched (`ex.call` stays `!ex.dyn`).
  """

  alias Beaver.MLIR
  alias Beaver.MLIR.IRMapping
  alias Beaver.MLIR.{IRRewriter, RewriterBase}
  alias Beaver.Walker

  @behaviour Batata.Transform.Pass

  @max_passes 64

  @impl Batata.Transform.Pass
  def run!(%MLIR.Module{} = module) do
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

    case module |> ops_of("ex.call") |> Enum.find(&match?({:ok, _}, resolve(&1, callees))) do
      nil ->
        :unchanged

      call ->
        {:ok, callee} = resolve(call, callees)
        inline!(call, callee)
        :changed
    end
  end

  defp resolve(call, callees) do
    name = call |> attribute_string("callee")
    arity = call |> attribute_integer("arity")

    with {:ok, callee} <- Map.fetch(callees, {name, arity}),
         true <- scalar?(callee),
         true <- scalar_args?(call) do
      {:ok, callee}
    else
      _ -> :skip
    end
  end

  defp scalar_args?(call) do
    call
    |> Walker.operands()
    |> Enum.all?(&(MLIR.to_string(MLIR.Value.type(&1)) == "i64"))
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
