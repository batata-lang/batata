defmodule Batata.CompilerKernel.PureScalarKernelTest do
  use ExUnit.Case, async: false

  alias Batata.CompilerKernel.Build
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Ex, as: ExConversion
  alias Beaver.MLIR.Conversion.Kernel.Error, as: KernelError
  alias Beaver.MLIR.Conversion.Plan

  @beaver_revision "2b0a1a32153fdef59affc439460cc9ce95b301c7"
  @digest "sha256:" <> String.duplicate("a", 64)
  @predicates ~w(eq ne slt sle sgt sge ult ule ugt uge)

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
    assert length(output.kernel_manifest.patterns) == 17

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
          "pattern.register"
        ]
      ]
    )
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
end
