defmodule Batata.Lower do
  @moduledoc """
  Lowers `ex` dialect IR to `func`/`arith`/`scf`/`cf` and then to LLVM.

  The conversion patterns live in Beaver
  (`Beaver.MLIR.Conversion.Ex`); this module wires them together with the
  standard `arith-to-llvm` and `func-to-llvm` passes for the lowering phase.
  """

  alias Batata.Lower.Trace
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
    {module, _stages} = do_to_func(module, opts, nil)
    module
  end

  @doc """
  Converts an `ex` dialect module to `func`/`arith`/`scf`/`cf` and returns a
  machine-readable native action trace.

  The trace is opt-in because MLIR action observation adds measurement
  overhead. Raw actions are reduced to bounded summaries grouped by action
  tag, root operation, and native description.
  """
  @spec to_func_with_trace(MLIR.Module.t(), keyword()) :: {MLIR.Module.t(), Trace.receipt()}
  def to_func_with_trace(module, opts \\ []) do
    ctx = MLIR.context(module)

    Trace.capture(ctx, :ex_to_func, fn session ->
      do_to_func(module, opts, session)
    end)
  end

  defp do_to_func(module, opts, session) do
    quota_bytes = opts |> Keyword.get(:memory_quota_bytes) |> RuntimeQuota.validate!()

    {module, stages} =
      maybe_stage(module, [], session, :runtime_quota, is_integer(quota_bytes), fn ->
        inject_runtime_quota!(module, quota_bytes)
      end)

    {module, stages} =
      run_conversion_stage(module, stages, session)

    maybe_stage(
      module,
      stages,
      session,
      :memory_accessors,
      Keyword.get(opts, :memory_telemetry, false),
      fn -> inject_result_memory_accessors!(module) end
    )
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
    {module, _stages} = do_to_llvm(module, ctx, opts, nil)
    module
  end

  @doc """
  Lowers an `ex` dialect module to LLVM and returns a machine-readable trace.

  The receipt separates the `ex` conversion and every standard MLIR lowering
  pass. Native `apply-conversion`, `apply-pattern`, and `pass-execution`
  actions are summarized within the stage that produced them.
  """
  @spec to_llvm_with_trace(MLIR.Module.t(), MLIR.Context.t(), keyword()) ::
          {MLIR.Module.t(), Trace.receipt()}
  def to_llvm_with_trace(module, ctx, opts \\ []) do
    Trace.capture(ctx, :ex_to_llvm, fn session ->
      do_to_llvm(module, ctx, opts, session)
    end)
  end

  @doc """
  Profiles LLVM lowering without discarding the receipt when lowering fails.

  The outcome is tagged so corpus diagnostics can retain every completed stage
  and the failed stage without weakening the ordinary raising API.
  """
  @spec profile_to_llvm(MLIR.Module.t(), MLIR.Context.t(), keyword()) ::
          {{:ok, MLIR.Module.t()} | {:error, atom(), term(), list()}, Trace.receipt()}
  def profile_to_llvm(module, ctx, opts \\ []) do
    Trace.capture_result(
      ctx,
      :ex_to_llvm,
      fn session ->
        do_to_llvm(module, ctx, opts, session)
      end,
      actions: false
    )
  end

  defp do_to_llvm(module, ctx, opts, session) do
    {module, stages} = do_to_func(module, opts, session)
    request_c_wrappers? = Keyword.get(opts, :c_interface, false)

    {module, stages} =
      run_stage(module, stages, session, :arith_to_llvm, fn ->
        run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionArithToLLVMConversionPass/0)
      end)

    {module, stages} =
      run_stage(module, stages, session, :scf_to_cf, fn ->
        run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionSCFToControlFlowPass/0)
      end)

    {module, stages} =
      run_stage(module, stages, session, :cf_to_llvm, fn ->
        run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionConvertControlFlowToLLVMPass/0)
      end)

    {module, stages} =
      maybe_stage(module, stages, session, :request_c_wrappers, request_c_wrappers?, fn ->
        request_c_wrappers_for_entries(module, [
          "main",
          "__batata_result_destroy",
          "__batata_result_root_kind",
          "__batata_result_root_word",
          "__batata_result_exception_kind",
          "__batata_result_exception_reason",
          "__batata_result_term_kind",
          "__batata_result_atom_name",
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
      end)

    run_stage(module, stages, session, :func_to_llvm, fn ->
      run_pass(module, ctx, &MLIR.CAPI.mlirCreateConversionConvertFuncToLLVMPass/0)
    end)
  end

  defp maybe_stage(module, stages, nil, _name, true, callback) do
    callback.()
    {module, stages}
  end

  defp maybe_stage(module, stages, session, name, true, callback) do
    run_stage(module, stages, session, name, fn ->
      callback.()
      module
    end)
  end

  defp maybe_stage(module, stages, _session, _name, false, _callback), do: {module, stages}

  defp run_stage(_module, stages, nil, _name, callback), do: {callback.(), stages}

  defp run_stage(_module, stages, session, name, callback) do
    {module, stage} = Trace.stage(session, name, callback)
    {module, stages ++ [stage]}
  end

  defp run_conversion_stage(module, stages, nil) do
    {Plan.run!(ExConversion.plan(), module), stages}
  end

  defp run_conversion_stage(module, stages, session) do
    {result, stage} =
      Trace.stage_with_details(session, :ex_conversion, fn ->
        {result, receipt} = Plan.profile(ExConversion.plan(), module)
        {result, %{"status" => receipt["status"], "conversion_profile" => receipt}}
      end)

    converted =
      case result do
        {:ok, converted, _diagnostics} -> converted
        {:error, error} -> raise error
      end

    {converted, stages ++ [stage]}
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
