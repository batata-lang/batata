defmodule Batata.Lower do
  @moduledoc """
  Lowers `ex` dialect IR to `func`/`arith`/`scf`/`cf` and then to LLVM.

  The conversion patterns live in Beaver
  (`Beaver.MLIR.Conversion.Ex`); this module wires them together with the
  standard `arith-to-llvm` and `func-to-llvm` passes for the lowering phase.
  """

  alias Batata.Memory.RuntimeQuota
  alias Beaver.Changeset
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Ex, as: ExConversion
  alias Beaver.MLIR.Conversion.Plan
  alias Beaver.MLIR.IRRewriter
  alias Beaver.MLIR.RewriterBase
  alias Beaver.Walker

  defmodule Error do
    @moduledoc "Raised when a standard MLIR lowering pass rejects the generated module."
    defexception [:message]
  end

  @doc """
  Converts an `ex` dialect module to `func`/`arith`/`scf`/`cf`.

  The module is converted in place and returned.
  """
  @runtime_quota_symbol "ex.term.runtime_set_arena_limit"
  @result_memory_accessors [
    {"__batata_result_arena_capacity_bytes", "ex.term.result_arena_capacity_bytes"},
    {"__batata_result_arena_chunks", "ex.term.result_arena_chunks"},
    {"__batata_result_arena_high_water", "ex.term.result_arena_high_water"},
    {"__batata_result_arena_limit", "ex.term.result_arena_limit"},
    {"__batata_result_oom", "ex.term.result_oom"}
  ]

  @spec to_func(MLIR.Module.t(), keyword()) :: MLIR.Module.t()
  def to_func(module, opts \\ []) do
    quota_bytes = opts |> Keyword.get(:memory_quota_bytes) |> RuntimeQuota.validate!()
    if is_integer(quota_bytes), do: inject_runtime_quota!(module, quota_bytes)
    module = Plan.run!(ExConversion.plan(), module)
    if Keyword.get(opts, :memory_telemetry, false), do: inject_result_memory_accessors!(module)
    module
  end

  @doc """
  Lowers an `ex` dialect module to LLVM dialect IR.

  Runs the ex conversion plan followed by the standard `arith-to-llvm` and
  `func-to-llvm` passes. With `c_interface: true`, requests C wrappers on the
  functions (`llvm-request-c-wrappers`) between the passes so they can be
  invoked through the MLIR JIT (`Beaver.MLIR.ExecutionEngine`). The module is
  converted in place and returned.
  """
  @spec to_llvm(MLIR.Module.t(), MLIR.Context.t(), keyword()) :: MLIR.Module.t()
  def to_llvm(module, ctx, opts \\ []) do
    module = to_func(module, opts)
    request_c_wrappers? = Keyword.get(opts, :c_interface, false)

    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionArithToLLVMConversionPass/0)
    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionSCFToControlFlowPass/0)
    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionConvertControlFlowToLLVMPass/0)

    if request_c_wrappers? do
      request_c_wrappers_for_entries(module, [
        "main",
        "__batata_result_destroy",
        "__batata_result_root_kind",
        "__batata_result_root_word",
        "__batata_result_exception_kind",
        "__batata_result_exception_reason",
        "__batata_result_term_kind",
        "__batata_result_term_length",
        "__batata_result_term_get",
        "__batata_result_arena_capacity_bytes",
        "__batata_result_arena_chunks",
        "__batata_result_arena_high_water",
        "__batata_result_arena_limit",
        "__batata_result_oom",
        "__batata_term_export",
        "__batata_term_import",
        "__batata_exported_clone",
        "__batata_exported_destroy",
        "__batata_exported_length",
        "__batata_exported_get",
        "__batata_term_handle_export",
        "__batata_term_handle_destroy"
      ])
    end

    run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionConvertFuncToLLVMPass/0)

    module
  end

  defp inject_runtime_quota!(module, quota_bytes) do
    owner = MLIR.Operation.from_module(module)
    body = MLIR.Module.body(module)
    runtime_creates = operations_named(body, "ex.runtime_create")

    IRRewriter.with_rewriter(owner, fn rewriter ->
      ensure_runtime_quota_declaration(rewriter, body, module)
      Enum.each(runtime_creates, &inject_runtime_quota_call(rewriter, &1, quota_bytes))
    end)
  end

  defp inject_runtime_quota_call(rewriter, runtime_create, quota_bytes) do
    RewriterBase.with_insertion_point(rewriter, {:after, runtime_create}, fn ->
      quota = quota_constant(runtime_create, quota_bytes)
      RewriterBase.insert(rewriter, quota)
      RewriterBase.set_insertion_point_after(rewriter, quota)
      RewriterBase.insert(rewriter, quota_call(runtime_create, quota))
    end)
  end

  defp inject_result_memory_accessors!(module) do
    owner = MLIR.Operation.from_module(module)
    body = MLIR.Module.body(module)

    IRRewriter.with_rewriter(owner, fn rewriter ->
      Enum.each(
        @result_memory_accessors,
        &inject_result_memory_accessor(rewriter, body, owner, &1)
      )
    end)
  end

  defp inject_result_memory_accessor(rewriter, body, owner, {wrapper, native}) do
    ensure_i64_declaration(rewriter, body, owner, native)

    unless Enum.any?(operations_named(body, "func.func"), &symbol?(&1, wrapper)) do
      insert_at_end(rewriter, body, i64_wrapper(owner, wrapper, native))
    end
  end

  defp ensure_i64_declaration(rewriter, body, owner, symbol) do
    unless Enum.any?(operations_named(body, "func.func"), &symbol?(&1, symbol)) do
      i64 = MLIR.Type.i64(ctx: MLIR.context(owner))
      declaration = func_operation(owner, symbol, [i64], [i64])

      insert_at_end(rewriter, body, declaration)
    end
  end

  defp insert_at_end(rewriter, body, operation) do
    RewriterBase.with_insertion_point(rewriter, {:end, body}, fn ->
      RewriterBase.insert(rewriter, operation)
    end)
  end

  defp i64_wrapper(owner, wrapper, native) do
    ctx = MLIR.context(owner)
    location = MLIR.Location.unknown(ctx: ctx)
    i64 = MLIR.Type.i64(ctx: ctx)
    region = MLIR.CAPI.mlirRegionCreate()
    block = MLIR.Block.create([i64], [location])
    MLIR.CAPI.mlirRegionAppendOwnedBlock(region, block)
    [argument] = block |> Walker.arguments() |> Enum.to_list()

    call =
      %Changeset{name: "func.call", context: ctx, location: location}
      |> Changeset.add_argument([argument])
      |> Changeset.add_argument(callee: MLIR.Attribute.flat_symbol_ref(native, ctx: ctx))
      |> Changeset.add_result(i64)
      |> MLIR.Operation.create()

    return =
      %Changeset{name: "func.return", context: ctx, location: location}
      |> Changeset.add_argument([MLIR.Operation.result(call, 0)])
      |> MLIR.Operation.create()

    MLIR.Block.append(block, call)
    MLIR.Block.append(block, return)
    func_operation(owner, wrapper, [i64], [i64], region)
  end

  defp func_operation(owner, symbol, arguments, results, region \\ nil) do
    changeset =
      %Changeset{
        name: "func.func",
        context: MLIR.context(owner),
        location: MLIR.Location.unknown(ctx: MLIR.context(owner))
      }
      |> Changeset.add_argument(sym_name: MLIR.Attribute.string(symbol))
      |> Changeset.add_argument(function_type: MLIR.Type.function(arguments, results))

    changeset =
      if region do
        Changeset.add_argument(changeset, region)
      else
        changeset
        |> Changeset.add_argument(sym_visibility: MLIR.Attribute.string("private"))
        |> Changeset.add_argument(MLIR.CAPI.mlirRegionCreate())
      end

    MLIR.Operation.create(changeset)
  end

  defp ensure_runtime_quota_declaration(rewriter, body, module) do
    unless Enum.any?(operations_named(body, "func.func"), &symbol?(&1, @runtime_quota_symbol)) do
      owner = MLIR.Operation.from_module(module)

      declaration =
        %Changeset{
          name: "func.func",
          context: MLIR.context(owner),
          location: MLIR.Location.unknown(ctx: MLIR.context(owner))
        }
        |> Changeset.add_argument(sym_name: MLIR.Attribute.string(@runtime_quota_symbol))
        |> Changeset.add_argument(sym_visibility: MLIR.Attribute.string("private"))
        |> Changeset.add_argument(
          function_type: MLIR.Type.function([MLIR.Type.i64(), MLIR.Type.i64()], [MLIR.Type.i64()])
        )
        |> Changeset.add_argument(MLIR.CAPI.mlirRegionCreate())
        |> MLIR.Operation.create()

      RewriterBase.with_insertion_point(rewriter, {:end, body}, fn ->
        RewriterBase.insert(rewriter, declaration)
      end)
    end
  end

  defp quota_constant(runtime_create, quota_bytes) do
    %Changeset{
      name: "arith.constant",
      context: MLIR.context(runtime_create),
      location: MLIR.Operation.location(runtime_create)
    }
    |> Changeset.add_argument(value: MLIR.Attribute.integer(MLIR.Type.i64(), quota_bytes))
    |> Changeset.add_result(MLIR.Type.i64())
    |> MLIR.Operation.create()
  end

  defp quota_call(runtime_create, quota) do
    %Changeset{
      name: "func.call",
      context: MLIR.context(runtime_create),
      location: MLIR.Operation.location(runtime_create)
    }
    |> Changeset.add_argument([
      MLIR.Operation.result(runtime_create, 0),
      MLIR.Operation.result(quota, 0)
    ])
    |> Changeset.add_argument(
      callee:
        MLIR.Attribute.flat_symbol_ref(@runtime_quota_symbol, ctx: MLIR.context(runtime_create))
    )
    |> Changeset.add_result(MLIR.Type.i64())
    |> MLIR.Operation.create()
  end

  defp operations_named(body, name) do
    body
    |> Walker.operations()
    |> Enum.flat_map(&all_operations/1)
    |> Enum.filter(&(MLIR.Operation.name(&1) == name))
  end

  defp all_operations(operation) do
    {_, operations} =
      Walker.postwalk(operation, [], fn
        %MLIR.Operation{} = op, acc -> {op, [op | acc]}
        entity, acc -> {entity, acc}
      end)

    Enum.reverse(operations)
  end

  defp symbol?(operation, expected) do
    case MLIR.Operation.fetch(operation, "sym_name") do
      {:ok, attribute} ->
        attribute |> MLIR.CAPI.mlirStringAttrGetValue() |> MLIR.to_string() == expected

      :error ->
        false
    end
  end

  # Asks func-to-llvm to emit a C interface wrapper (`_mlir_ciface_*`) only for
  # the entry function. The Zig term runtime declarations must not get
  # wrappers: the generated `_mlir_ciface_*` symbols have no body and would
  # fail JIT materialization.
  defp request_c_wrappers_for_entries(module, sym_names) do
    module
    |> MLIR.Module.body()
    |> Walker.operations()
    |> Enum.filter(fn op ->
      MLIR.Operation.name(op) == "func.func" and symbol_name(op) in sym_names
    end)
    |> Enum.each(fn entry ->
      MLIR.Operation.get_and_update(entry, "llvm.emit_c_interface", fn _ ->
        {nil, MLIR.Attribute.unit()}
      end)
    end)

    module
  end

  defp symbol_name(op) do
    case op |> MLIR.Operation.fetch("sym_name") do
      {:ok, attribute} -> attribute |> MLIR.CAPI.mlirStringAttrGetValue() |> MLIR.to_string()
      :error -> nil
    end
  end

  defp run_pass(module, ctx, pass_fun) do
    pass_manager = MLIR.CAPI.mlirPassManagerCreate(ctx)

    try do
      MLIR.CAPI.mlirPassManagerAddOwnedPass(pass_manager, pass_fun.())

      case MLIR.PassManager.run(pass_manager, module) do
        {:ok, _diagnostics} ->
          :ok

        {:error, diagnostics} ->
          raise Error,
            message: MLIR.Diagnostic.format(diagnostics, "standard MLIR lowering pass failed")
      end
    after
      MLIR.PassManager.destroy(pass_manager)
    end

    module
  end
end
