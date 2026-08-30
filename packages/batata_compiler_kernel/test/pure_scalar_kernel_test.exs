defmodule Batata.CompilerKernel.PureScalarKernelTest do
  use ExUnit.Case, async: false

  alias Batata.CompilerKernel.Build
  alias Batata.CompilerKernel.Provider
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Ex, as: ExConversion
  alias Beaver.MLIR.Conversion.Kernel.Error, as: KernelError
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest
  alias Beaver.MLIR.Conversion.Plan

  @beaver_revision "282d2b1d5ab5b2711b41dd19708526dc3019c52a"
  @digest "sha256:" <> String.duplicate("a", 64)
  @predicates ~w(eq ne slt sle sgt sge ult ule ugt uge)
  @scheduler_shapes [
    {"ex.self", [], "!ex.term"},
    {"ex.send", ["!ex.term", "!ex.term"], "!ex.term"},
    {"ex.receive", [], "!ex.term"},
    {"ex.mailbox_clear", [], "!ex.term"},
    {"ex.spawn", ["!ex.term"], "!ex.term"},
    {"ex.schedule_next", [], "i64"},
    {"ex.current_entry", [], "i64"},
    {"ex.process_done", ["i64"], "i64"},
    {"ex.process_exit", ["!ex.term"], "!ex.term"},
    {"ex.process_exit_reason", ["!ex.term"], "!ex.term"},
    {"ex.process_trap_exit", ["i64"], "i64"},
    {"ex.link", ["!ex.term", "!ex.term", "!ex.term"], "!ex.term"},
    {"ex.unlink", ["!ex.term"], "i64"},
    {"ex.exit", ["!ex.term", "!ex.term", "!ex.term", "!ex.term"], "!ex.term"},
    {"ex.monitor", ["!ex.term", "!ex.term", "!ex.term", "!ex.term"], "!ex.term"},
    {"ex.demonitor", ["!ex.term"], "i64"},
    {"ex.processes_runnable", [], "i64"},
    {"ex.process_result", ["!ex.term"], "i64"},
    {"ex.cont_save", ["i64", "i64", "i64"], "i64"},
    {"ex.receive_cont_save", ["i64", "i64", "i64"], "i64"},
    {"ex.cont_pending", [], "i64"},
    {"ex.cont_active", [], "i64"},
    {"ex.cont_clear", [], "i64"},
    {"ex.cont_load_arg", [], "i64"},
    {"ex.cont_load_acc", [], "i64"},
    {"ex.cont_load_cursor", [], "i64"},
    {"ex.clock_init", ["i64"], "i64"},
    {"ex.reduction_tick", ["i64"], "i64"},
    {"ex.yield_mark", [], "i64"},
    {"ex.mailbox_len", [], "i64"},
    {"ex.mailbox_peek", ["i64"], "!ex.term"},
    {"ex.mailbox_remove", ["i64"], "i64"},
    {"ex.nil_word", [], "!ex.term"},
    {"ex.monotonic_time", [], "i64"},
    {"ex.receive_start", [], "i64"},
    {"ex.receive_start_set", ["i64"], "i64"},
    {"ex.native_time", [], "i64"},
    {"ex.unique_integer", ["i64"], "i64"},
    {"ex.to_int", ["!ex.term"], "i64"}
  ]

  setup do
    ctx = MLIR.Context.create()
    MLIR.Context.allow_unregistered_dialects(ctx)
    on_exit(fn -> MLIR.Context.destroy(ctx) end)
    %{ctx: ctx}
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT pure-scalar kernel matches the frozen C++ Stage 0", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())
    assert File.regular?(output.library)
    assert File.regular?(output.kernel_manifest_path)
    assert length(output.kernel_manifest.patterns) == 151

    for predicate <- @predicates do
      stage0 = input_module(ctx, predicate)
      native = input_module(ctx, predicate)

      Plan.run!(ExConversion.plan(), stage0)
      Plan.run!(native_plan(output), native)

      stage0_ir = MLIR.to_string(stage0)
      native_ir = MLIR.to_string(native)
      assert native_ir == stage0_ir

      for operation <-
            ~w(arith.constant arith.addi arith.subi arith.muli arith.divsi arith.remsi arith.cmpi arith.extui) do
        assert native_ir =~ operation
      end

      refute native_ir =~ ~r/"ex\.(lit|add|sub|mul|div|rem|cmp|to_word|unbox)"/
      MLIR.Module.destroy(stage0)
      MLIR.Module.destroy(native)
    end

    declaration = Plan.declaration(native_plan(output))
    assert Enum.any?(declaration.entries, &(&1.kind == :add_external_pattern_population))
    refute Enum.any?(declaration.entries, &(&1.kind == :add_conversion_pattern))
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT kernel fails before conversion on target drift", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())
    module = input_module(ctx, "eq")

    assert %KernelError{code: :target_mismatch} =
             assert_raise(KernelError, fn ->
               Plan.run!(native_plan(output, Map.put(target(), "cpu", "foreign")), module)
             end)

    rendered = MLIR.to_string(module)
    assert rendered =~ "ex.add"
    refute rendered =~ "arith.addi"
    MLIR.Module.destroy(module)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT ex.yield matches the frozen native seed", %{ctx: ctx, tmp_dir: tmp_dir} do
    output = Build.build!(tmp_dir, ctx, build_options())
    stage0 = yield_module(ctx)
    native = yield_module(ctx)

    Plan.run!(stage0_yield_plan(), stage0)
    Plan.run!(Plan.add_legal_op(native_plan(output), "fixture.region"), native)

    assert MLIR.to_string(native) == MLIR.to_string(stage0)
    assert MLIR.to_string(native) =~ "scf.yield"
    refute MLIR.to_string(native) =~ "ex.yield"
    MLIR.Module.destroy(stage0)
    MLIR.Module.destroy(native)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT runtime-call kernel matches the frozen C++ Stage 0", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())
    stage0 = runtime_module(ctx)
    native = runtime_module(ctx)

    Plan.run!(ExConversion.plan(), stage0)
    Plan.run!(native_plan(output), native)

    stage0_ir = MLIR.to_string(stage0, generic: true)
    native_ir = MLIR.to_string(native, generic: true)
    assert native_ir == stage0_ir

    for symbol <- ~w(ex.term.eq ex.term.binary_part ex.term.list_cons ex.term.binary_from_list) do
      assert length(Regex.scan(~r/sym_name = "#{Regex.escape(symbol)}"/, native_ir)) == 1
    end

    assert length(Regex.scan(~r/callee = @ex\.term\.list_cons/, native_ir)) == 2
    refute native_ir =~ ~r/"ex\.(term_eq|binary_part|binary)"/
    MLIR.Module.destroy(stage0)
    MLIR.Module.destroy(native)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT kernel rejects runtime ABI drift before conversion", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())
    module = runtime_module(ctx)

    assert %KernelError{code: :runtime_abi_mismatch} =
             assert_raise(KernelError, fn ->
               Plan.run!(native_plan(output, target(), @digest), module)
             end)

    rendered = MLIR.to_string(module)
    assert rendered =~ "ex.term_eq"
    refute rendered =~ "ex.term.eq"
    MLIR.Module.destroy(module)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT lifecycle kernel matches the BEAM reference", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())
    reference = lifecycle_module(ctx)
    native = lifecycle_module(ctx)

    Plan.run!(ExConversion.plan(), reference)
    Plan.run!(native_plan(output), native)

    reference_ir = MLIR.to_string(reference, generic: true)
    native_ir = MLIR.to_string(native, generic: true)
    assert native_ir == reference_ir

    for root <-
          ~w(
            runtime_create runtime_enter runtime_leave runtime_destroy
            result_create result_destroy result_root_kind result_root_word
            result_exception_kind result_exception_reason result_term_kind
            result_atom_name result_term_length result_term_get term_export
            term_import exported_clone exported_destroy exported_length
            exported_get term_handle_export term_handle_destroy
            process_table_reset
          ) do
      refute native_ir =~ ~s|"ex.#{root}"|
    end

    MLIR.Module.destroy(reference)
    MLIR.Module.destroy(native)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT scheduler and actor kernel matches the BEAM reference", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())
    reference = scheduler_module(ctx)
    native = scheduler_module(ctx)

    Plan.run!(ExConversion.plan(), reference)
    Plan.run!(native_plan(output), native)

    reference_ir = MLIR.to_string(reference, generic: true)
    native_ir = MLIR.to_string(native, generic: true)
    assert native_ir == reference_ir

    for {root, _operand_types, _result_type} <- @scheduler_shapes do
      refute native_ir =~ ~s|"#{root}"|
    end

    MLIR.Module.destroy(reference)
    MLIR.Module.destroy(native)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT term-library kernel matches the BEAM reference", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())
    reference = term_library_module(ctx)
    native = term_library_module(ctx)

    Plan.run!(ExConversion.plan(), reference)
    Plan.run!(native_plan(output), native)

    reference_ir = MLIR.to_string(reference, generic: true)
    native_ir = MLIR.to_string(native, generic: true)
    assert native_ir == reference_ir

    for root <-
          ~w(
            list_flatten map_put string_to_existing_atom binary_utf8_width
            enumerable_reduce_c enumerable_map_term_fun_c fun_result_mode
            list_cons process_wait worker_run catch_value throw raise
          ) do
      refute native_ir =~ ~s|"ex.#{root}"|
    end

    MLIR.Module.destroy(reference)
    MLIR.Module.destroy(native)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT boxing and term predicates preserve source-type semantics", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    assert ctx
           |> Beaver.Slang.load(Beaver.MLIR.Dialect.Ex)
           |> MLIR.LogicalResult.success?()

    output = Build.build!(tmp_dir, ctx, build_options())
    reference = boxing_predicate_module(ctx)
    native = boxing_predicate_module(ctx)

    Plan.run!(ExConversion.plan(), reference)
    Plan.run!(native_plan(output), native)

    reference_ir = MLIR.to_string(reference, generic: true)
    native_ir = MLIR.to_string(native, generic: true)
    assert native_ir == reference_ir
    assert native_ir =~ ~s|"arith.shli"|

    for symbol <- ~w(is_integer is_float is_atom is_binary is_list is_tuple is_map) do
      assert native_ir =~ ~s|callee = @ex.term.#{symbol}|
      refute native_ir =~ ~s|"ex.#{symbol}"|
    end

    refute native_ir =~ ~s|"ex.box"|
    MLIR.Module.destroy(reference)
    MLIR.Module.destroy(native)

    invalid =
      MLIR.Module.create!(
        ~S[module { func.func @invalid(%value: f64) -> !ex.term { %0 = "ex.box"(%value) : (f64) -> !ex.term func.return %0 : !ex.term } }],
        ctx: ctx
      )

    assert {:error, %MLIR.Conversion.Error{diagnostics: diagnostics}} =
             Plan.run(native_plan(output), invalid)

    assert diagnostics != []
    invalid_ir = MLIR.to_string(invalid, generic: true)
    assert invalid_ir =~ ~s|"ex.box"|
    refute invalid_ir =~ ~s|"arith.shli"|
    MLIR.Module.destroy(invalid)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT aggregate constructors match the BEAM reference and reject odd maps", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    assert ctx
           |> Beaver.Slang.load(Beaver.MLIR.Dialect.Ex)
           |> MLIR.LogicalResult.success?()

    output = Build.build!(tmp_dir, ctx, build_options())
    reference = aggregate_module(ctx)
    native = aggregate_module(ctx)

    Plan.run!(ExConversion.plan(), reference)
    Plan.run!(native_plan(output), native)

    reference_ir = MLIR.to_string(reference, generic: true)
    native_ir = MLIR.to_string(native, generic: true)
    assert native_ir == reference_ir
    assert native_ir =~ ~s|callee = @ex.term.tuple_from_list|
    assert native_ir =~ ~s|callee = @ex.term.map_from_list|
    refute native_ir =~ ~r/"ex\.(list|tuple|map)"/

    MLIR.Module.destroy(reference)
    MLIR.Module.destroy(native)

    invalid = odd_map_module(ctx)

    assert {:error, %MLIR.Conversion.Error{diagnostics: diagnostics}} =
             Plan.run(native_plan(output), invalid)

    assert diagnostics != []
    invalid_ir = MLIR.to_string(invalid, generic: true)
    assert invalid_ir =~ ~s|"ex.map"|
    refute invalid_ir =~ ~s|callee = @ex.term.list_cons|
    refute invalid_ir =~ ~s|callee = @ex.term.map_from_list|
    MLIR.Module.destroy(invalid)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT region/function kernel matches the Stage 0 and BEAM seed", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())
    reference = control_function_module(ctx)
    native = control_function_module(ctx)

    Plan.run!(ExConversion.plan(), reference)
    Plan.run!(native_plan(output), native)

    reference_ir = MLIR.to_string(reference, generic: true)
    native_ir = MLIR.to_string(native, generic: true)
    assert native_ir == reference_ir
    assert native_ir =~ ~s|"func.func"()|
    assert native_ir =~ ~s|"func.call"|
    assert native_ir =~ ~s|"scf.if"|
    assert native_ir =~ ~s|"func.return"|
    refute native_ir =~ ~r/"ex\.(func|call|if|return|yield)"/
    MLIR.Module.destroy(reference)
    MLIR.Module.destroy(native)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT call conversion rejects arity drift without partial IR", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build!(tmp_dir, ctx, build_options())

    module =
      MLIR.Module.create!(
        ~S"""
        module {
          func.func @bad_call(%a: i64, %b: i64) -> i64 {
            %0 = "ex.call"(%a, %b) {callee = "add", arity = 1 : i64, operandSegmentSizes = array<i32: 1, 1, 0, 0, 0, 0, 0, 0>} : (i64, i64) -> i64
            func.return %0 : i64
          }
        }
        """,
        ctx: ctx
      )

    assert {:error, %MLIR.Conversion.Error{diagnostics: diagnostics}} =
             Plan.run(native_plan(output), module)

    assert diagnostics != []
    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ ~s|"ex.call"|
    refute rendered =~ ~s|"func.call"|
    MLIR.Module.destroy(module)
  end

  @tag :tmp_dir
  @tag timeout: 240_000
  test "Stage 1 rebuilds a parity-equivalent Stage 2 with an auditable receipt", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    stage1 = Build.build!(Path.join(tmp_dir, "stage1"), ctx, build_options())
    stage2 = Build.rebuild!(Path.join(tmp_dir, "stage2"), ctx, stage1, build_options())

    stage1_identity =
      KernelManifest.identity_digest(stage1.kernel_manifest)

    assert stage1.kernel_manifest.bootstrap["stage"] == "stage1"
    assert stage1.kernel_manifest.bootstrap["seed"] == "cpp-bootstrap"
    assert stage2.kernel_manifest.bootstrap["stage"] == "stage2"
    assert stage2.kernel_manifest.bootstrap["seed"] == "previous-native"

    assert stage2.kernel_manifest.bootstrap["provenance"] ==
             "batata-stage1:" <> stage1_identity

    assert stage2.kernel_manifest.patterns == stage1.kernel_manifest.patterns
    assert stage2.kernel_manifest.capabilities == stage1.kernel_manifest.capabilities
    assert stage2.lowered_ir_digest == stage1.lowered_ir_digest
    assert digest_file(stage2.object) == digest_file(stage1.object)

    receipt_bytes = File.read!(stage2.bootstrap_receipt)
    receipt = JSON.decode!(receipt_bytes)
    assert receipt_bytes == Batata.Memory.canonical_json(receipt) <> "\n"
    assert receipt["source_kernel_identity"] == stage1_identity
    assert receipt["lowered_ir_sha256"] == stage1.lowered_ir_digest
    assert receipt["object_sha256"] == digest_file(stage1.object)

    module = control_function_module(ctx)
    Plan.run!(native_plan(stage2), module)
    refute MLIR.to_string(module, generic: true) =~ ~r/"ex\./
    MLIR.Module.destroy(module)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Stage 2 rebuild rejects a Stage 1 artifact from another target", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    stage1 = Build.build!(Path.join(tmp_dir, "stage1"), ctx, build_options())
    stage2_dir = Path.join(tmp_dir, "stage2")

    assert_raise KernelError, ~r/target_mismatch/, fn ->
      Build.rebuild!(
        stage2_dir,
        ctx,
        stage1,
        Keyword.put(build_options(), :target, "x86_64-unknown-linux-gnu")
      )
    end

    refute File.exists?(Path.join(stage2_dir, "batata-ex-conversion.o"))
  end

  @tag :tmp_dir
  @tag timeout: 240_000
  test "production provider emits a zero-callback Stage 2 receipt", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    stage1 = Build.build!(Path.join(tmp_dir, "stage1"), ctx, build_options())
    stage2 = Build.rebuild!(Path.join(tmp_dir, "stage2"), ctx, stage1, build_options())
    receipt_path = Path.join(tmp_dir, "production-conversion-receipt.json")
    module = control_function_module(ctx)

    {^module, receipt} =
      Provider.profile!(
        stage2.kernel_manifest,
        stage2.library,
        module,
        receipt_path,
        provider_options()
      )

    assert receipt["callback_free"] == true
    assert receipt["kernel_identity"] == KernelManifest.identity_digest(stage2.kernel_manifest)
    assert receipt["bootstrap"] == stage2.kernel_manifest.bootstrap
    assert receipt["conversion"]["status"] == "ok"
    assert receipt["conversion"]["beam"]["callback_count"] == 0
    assert receipt["conversion"]["beam"]["max_in_flight"] == 0
    assert receipt["conversion"]["callbacks"] == []

    bytes = File.read!(receipt_path)
    assert bytes == Batata.Memory.canonical_json(receipt) <> "\n"
    refute MLIR.to_string(module, generic: true) =~ ~r/"ex\./
    MLIR.Module.destroy(module)
  end

  @tag :tmp_dir
  test "Batata compiler-kernel build rejects implicit fallback policy", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    assert_raise ArgumentError, ~r/unknown compiler-kernel build options/, fn ->
      Build.build!(tmp_dir, ctx, Keyword.put(build_options(), :fallback, :stage0))
    end
  end

  defp native_plan(
         output,
         expected_target \\ target(),
         expected_runtime_abi \\ Batata.TermRuntime.abi_digest()
       ) do
    Plan.new(mode: :full, folding_mode: :after_patterns, build_materializations: true)
    |> Plan.add_legal_dialect("builtin")
    |> Plan.add_legal_dialect("func")
    |> Plan.add_legal_dialect("arith")
    |> Plan.add_legal_dialect("cf")
    |> Plan.add_legal_dialect("scf")
    |> Plan.add_legal_dialect("llvm")
    |> Plan.add_illegal_dialect("ex")
    |> Plan.add_conversion_map(~w(!ex.term !ex.bound !ex.unbound), "i64")
    |> Plan.add_external_pattern_population(output.kernel_manifest, output.library,
      expected: [
        beaver_revision: @beaver_revision,
        dialect_schema_digest: @digest,
        runtime_abi_digest: expected_runtime_abi,
        target: expected_target,
        capabilities: [
          "ir.attribute.v1",
          "ir.region.v1",
          "ir.scalar.v1",
          "ir.symbol.v1",
          "ir.type.v1",
          "pattern.register"
        ]
      ]
    )
  end

  defp provider_options do
    [
      beaver_revision: @beaver_revision,
      dialect_schema_digest: @digest,
      runtime_abi_digest: Batata.TermRuntime.abi_digest(),
      target: target()
    ]
  end

  defp stage0_yield_plan do
    Plan.new(mode: :full, folding_mode: :after_patterns, build_materializations: true)
    |> Plan.add_legal_dialect("builtin")
    |> Plan.add_legal_dialect("func")
    |> Plan.add_legal_dialect("arith")
    |> Plan.add_legal_dialect("scf")
    |> Plan.add_legal_op("fixture.region")
    |> Plan.add_illegal_dialect("ex")
    |> Plan.add_conversion_map(~w(!ex.term !ex.bound !ex.unbound), "i64")
    |> Plan.add_pattern_population(
      fn patterns, converter ->
        MLIR.CAPI.beaverPopulateExScalarConversionPatterns(patterns.ref, converter.ref)
      end,
      version: "stage0"
    )
  end

  defp input_module(ctx, predicate) do
    MLIR.Module.create!(
      """
      module {
        func.func @scalar(%a: i64, %b: i64) -> i64 {
          %lit = "ex.lit"() {value = 7 : i64} : () -> i64
          %add = "ex.add"(%a, %b) : (i64, i64) -> i64
          %sub = "ex.sub"(%add, %lit) : (i64, i64) -> i64
          %mul = "ex.mul"(%sub, %lit) : (i64, i64) -> i64
          %div = "ex.div"(%mul, %lit) : (i64, i64) -> i64
          %rem = "ex.rem"(%div, %lit) : (i64, i64) -> i64
          %cmp = "ex.cmp"(%rem, %lit) {predicate = "#{predicate}"} : (i64, i64) -> i64
          %term = "ex.to_word"(%cmp) : (i64) -> !ex.term
          %word = "ex.unbox"(%term) : (!ex.term) -> i64
          func.return %word : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp yield_module(ctx) do
    MLIR.Module.create!(
      """
      module {
        func.func @yield() {
          "fixture.region"() ({
            "ex.yield"() : () -> ()
          }) : () -> ()
          func.return
        }
      }
      """,
      ctx: ctx
    )
  end

  defp runtime_module(ctx) do
    MLIR.Module.create!(
      """
      module {
        func.func @runtime(%a: i64, %b: i64, %start: i64) -> i64 {
          %term_a = "ex.to_word"(%a) : (i64) -> !ex.term
          %term_b = "ex.to_word"(%b) : (i64) -> !ex.term
          %term_start = "ex.to_word"(%start) : (i64) -> !ex.term
          %eq = "ex.term_eq"(%term_a, %term_b) : (!ex.term, !ex.term) -> i64
          %part = "ex.binary_part"(%term_a, %term_start, %term_b) : (!ex.term, !ex.term, !ex.term) -> !ex.term
          %binary = "ex.binary"(%term_a, %part) : (!ex.term, !ex.term) -> !ex.term
          %word = "ex.unbox"(%binary) : (!ex.term) -> i64
          func.return %word : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp control_function_module(ctx) do
    MLIR.Module.create!(
      ~S"""
      module {
        func.func @add(%a: i64, %b: i64) -> i64 {
          %result = arith.addi %a, %b : i64
          func.return %result : i64
        }
        "ex.func"() ({
        ^bb0:
          %0 = "ex.lit"() {value = 1 : i64} : () -> i64
          %1 = "ex.lit"() {value = 2 : i64} : () -> i64
          %2 = "ex.cmp"(%0, %1) {predicate = "slt"} : (i64, i64) -> i64
          %3 = "ex.if"(%2) ({
            "ex.yield"(%0) {operandSegmentSizes = array<i32: 1>} : (i64) -> ()
          }, {
            "ex.yield"(%1) {operandSegmentSizes = array<i32: 1>} : (i64) -> ()
          }) {operandSegmentSizes = array<i32: 1>} : (i64) -> i64
          %4 = "ex.call"(%3, %1) {callee = "add", arity = 2 : i64, operandSegmentSizes = array<i32: 1, 1, 0, 0, 0, 0, 0, 0>} : (i64, i64) -> i64
          "ex.return"(%4) {operandSegmentSizes = array<i32: 1>} : (i64) -> ()
        }) {sym_name = "main"} : () -> ()
      }
      """,
      ctx: ctx
    )
  end

  defp lifecycle_module(ctx) do
    MLIR.Module.create!(
      ~S"""
      module {
        func.func @lifecycle(%word: i64) -> i64 {
          %runtime = "ex.runtime_create"() : () -> i64
          %entered = "ex.runtime_enter"(%runtime) : (i64) -> i64
          %left = "ex.runtime_leave"() : () -> i64
          %result = "ex.result_create"(%runtime, %word) : (i64, i64) -> i64
          %root_kind = "ex.result_root_kind"(%result) : (i64) -> i64
          %root_word = "ex.result_root_word"(%result) : (i64) -> i64
          %exception_kind = "ex.result_exception_kind"(%result) : (i64) -> i64
          %exception_reason = "ex.result_exception_reason"(%result) : (i64) -> i64
          %term_kind = "ex.result_term_kind"(%result, %word) : (i64, i64) -> i64
          %atom_name = "ex.result_atom_name"(%result, %word) : (i64, i64) -> i64
          %term_length = "ex.result_term_length"(%result, %word) : (i64, i64) -> i64
          %term_get = "ex.result_term_get"(%result, %word, %word) : (i64, i64, i64) -> i64
          %exported = "ex.term_export"(%result, %word) : (i64, i64) -> i64
          %imported = "ex.term_import"(%runtime, %exported) : (i64, i64) -> i64
          %clone = "ex.exported_clone"(%exported) : (i64) -> i64
          %exported_length = "ex.exported_length"(%clone) : (i64) -> i64
          %exported_get = "ex.exported_get"(%clone, %word) : (i64, i64) -> i64
          %handle_export = "ex.term_handle_export"(%imported) : (i64) -> i64
          %handle_destroy = "ex.term_handle_destroy"(%imported) : (i64) -> i64
          %exported_destroy = "ex.exported_destroy"(%clone) : (i64) -> i64
          %reset = "ex.process_table_reset"(%word) : (i64) -> i64
          %result_destroy = "ex.result_destroy"(%result) : (i64) -> i64
          %runtime_destroy = "ex.runtime_destroy"(%runtime) : (i64) -> i64
          func.return %runtime_destroy : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp scheduler_module(ctx) do
    operations =
      @scheduler_shapes
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{root, operand_types, result_type}, index} ->
        operands =
          Enum.map_join(operand_types, ", ", fn
            "i64" -> "%int"
            "!ex.term" -> "%term"
          end)

        operand_types = Enum.join(operand_types, ", ")

        "          %v#{index} = \"#{root}\"(#{operands}) : (#{operand_types}) -> #{result_type}"
      end)

    MLIR.Module.create!(
      """
      module {
        func.func @scheduler(%int: i64) -> i64 {
          %term = "ex.to_word"(%int) : (i64) -> !ex.term
      #{operations}
          func.return %v#{length(@scheduler_shapes) - 1} : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp term_library_module(ctx) do
    MLIR.Module.create!(
      ~S"""
      module {
        func.func @term_library(
          %int: i64,
          %fun1: (i64) -> i64,
          %fun8: (i64, i64, i64, i64, i64, i64, i64, i64) -> i64
        ) -> i64 {
          %term = "ex.to_word"(%int) : (i64) -> !ex.term
          %list = "ex.list_flatten"(%term) : (!ex.term) -> !ex.term
          %map = "ex.map_put"(%list, %term, %term) : (!ex.term, !ex.term, !ex.term) -> !ex.term
          %atom = "ex.string_to_existing_atom"(%term) : (!ex.term) -> !ex.term
          %width = "ex.binary_utf8_width"(%atom, %int) : (!ex.term, i64) -> i64
          %reduced = "ex.enumerable_reduce_c"(%map, %int, %width, %int) : (!ex.term, i64, i64, i64) -> i64
          %mapped = "ex.enumerable_map_term_fun_c"(%map, %fun8, %int, %width, %reduced, %int) : (!ex.term, (i64, i64, i64, i64, i64, i64, i64, i64) -> i64, i64, i64, i64, i64) -> !ex.term
          %mode = "ex.fun_result_mode"(%mapped) : (!ex.term) -> i64
          %cons = "ex.list_cons"(%mapped, %term) : (!ex.term, !ex.term) -> !ex.term
          %waited = "ex.process_wait"(%int) : (i64) -> i64
          %worked = "ex.worker_run"(%waited, %fun1) : (i64, (i64) -> i64) -> i64
          %caught = "ex.catch_value"() : () -> !ex.term
          %thrown = "ex.throw"(%caught) : (!ex.term) -> !ex.term
          %raised = "ex.raise"(%thrown, %worked) : (!ex.term, i64) -> !ex.term
          func.return %mode : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp boxing_predicate_module(ctx) do
    predicates = ~w(is_integer is_float is_atom is_binary is_list is_tuple is_map)

    operations =
      predicates
      |> Enum.with_index()
      |> Enum.flat_map(fn {predicate, index} ->
        [
          ~s|          %scalar_#{index} = "ex.#{predicate}"(%scalar) : (i64) -> i64|,
          ~s|          %term_#{index} = "ex.#{predicate}"(%boxed_again) : (!ex.term) -> i64|
        ]
      end)
      |> Enum.join("\n")

    MLIR.Module.create!(
      """
      module {
        func.func @boxing_predicates(%scalar: i64) -> i64 {
          %boxed = "ex.box"(%scalar) : (i64) -> !ex.term
          %boxed_again = "ex.box"(%boxed) : (!ex.term) -> !ex.term
      #{operations}
          func.return %term_6 : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp aggregate_module(ctx) do
    MLIR.Module.create!(
      ~S"""
      module {
        func.func @aggregates(%first_word: i64, %second_word: i64) -> i64 {
          %first = "ex.box"(%first_word) : (i64) -> !ex.term
          %second = "ex.box"(%second_word) : (i64) -> !ex.term
          %list = "ex.list"(%first, %second) : (!ex.term, !ex.term) -> !ex.term
          %tuple = "ex.tuple"(%list, %first) : (!ex.term, !ex.term) -> !ex.term
          %map = "ex.map"(%first, %tuple, %second, %list) : (!ex.term, !ex.term, !ex.term, !ex.term) -> !ex.term
          %result = "ex.unbox"(%map) : (!ex.term) -> i64
          func.return %result : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp odd_map_module(ctx) do
    MLIR.Module.create!(
      ~S"""
      module {
        func.func @odd_map(%word: i64) -> i64 {
          %term = "ex.box"(%word) : (i64) -> !ex.term
          %map = "ex.map"(%term) : (!ex.term) -> !ex.term
          %result = "ex.unbox"(%map) : (!ex.term) -> i64
          func.return %result : i64
        }
      }
      """,
      ctx: ctx
    )
  end

  defp build_options do
    [
      compiler_revision: "batata-stage1-kernel-fixture",
      beaver_revision: @beaver_revision,
      dialect_schema_digest: @digest,
      runtime_abi_digest: Batata.TermRuntime.abi_digest(),
      target: target(),
      bootstrap_provenance: "beaver-stage0:#{@beaver_revision}",
      dependency_pins: %{
        "beaver" => @beaver_revision,
        "llvm" => MLIR.CompilationRuntime.llvm_revision()
      }
    ]
  end

  defp target, do: %{"triple" => "host-test", "cpu" => "generic", "features" => []}

  defp digest_file(path) do
    "sha256:" <>
      (path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower))
  end
end
