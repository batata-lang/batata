defmodule Batata.CompilerKernel.PureScalarKernelTest do
  use ExUnit.Case, async: false

  alias Batata.CompilerKernel.Build
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Ex, as: ExConversion
  alias Beaver.MLIR.Conversion.Kernel.Error, as: KernelError
  alias Beaver.MLIR.Conversion.Plan

  @beaver_revision "1e1be0205ae31d5804064f230b74d76a6e80ba2b"
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
    output = Build.build_pure_scalar!(tmp_dir, ctx, build_options())
    assert File.regular?(output.library)
    assert File.regular?(output.kernel_manifest_path)
    assert length(output.kernel_manifest.patterns) == 10

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
    output = Build.build_pure_scalar!(tmp_dir, ctx, build_options())
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
    output = Build.build_pure_scalar!(tmp_dir, ctx, build_options())
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
  test "Batata compiler-kernel build rejects implicit fallback policy", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    assert_raise ArgumentError, ~r/unknown compiler-kernel build options/, fn ->
      Build.build_pure_scalar!(tmp_dir, ctx, Keyword.put(build_options(), :fallback, :stage0))
    end
  end

  defp native_plan(output, expected_target \\ target()) do
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
        runtime_abi_digest: "none",
        target: expected_target,
        capabilities: ["ir.attribute.v1", "ir.scalar.v1", "pattern.register"]
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

  defp build_options do
    [
      compiler_revision: "batata-stage1-pure-scalar-fixture",
      beaver_revision: @beaver_revision,
      dialect_schema_digest: @digest,
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
