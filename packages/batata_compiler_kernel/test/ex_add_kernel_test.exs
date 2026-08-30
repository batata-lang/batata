defmodule Batata.CompilerKernel.ExAddKernelTest do
  use ExUnit.Case, async: false

  alias Batata.CompilerKernel.Build
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Ex, as: ExConversion
  alias Beaver.MLIR.Conversion.Kernel.Error, as: KernelError
  alias Beaver.MLIR.Conversion.Plan

  @beaver_revision "d972dc93e6245fc4f68e8b3cc848db2e258e92ca"
  @digest "sha256:" <> String.duplicate("a", 64)

  setup do
    ctx = MLIR.Context.create()
    MLIR.Context.allow_unregistered_dialects(ctx)
    on_exit(fn -> MLIR.Context.destroy(ctx) end)
    %{ctx: ctx}
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT ex.add kernel matches the frozen C++ Stage 0", %{ctx: ctx, tmp_dir: tmp_dir} do
    output = Build.build_ex_add!(tmp_dir, ctx, build_options())
    assert File.regular?(output.library)
    assert File.regular?(output.kernel_manifest_path)

    stage0 = input_module(ctx)
    native = input_module(ctx)

    Plan.run!(ExConversion.plan(), stage0)
    Plan.run!(native_plan(output), native)

    stage0_ir = MLIR.to_string(stage0)
    native_ir = MLIR.to_string(native)
    assert native_ir == stage0_ir
    assert native_ir =~ "arith.addi"
    refute native_ir =~ "ex.add"

    declaration = Plan.declaration(native_plan(output))
    assert Enum.any?(declaration.entries, &(&1.kind == :add_external_pattern_population))
    refute Enum.any?(declaration.entries, &(&1.kind == :add_conversion_pattern))

    MLIR.Module.destroy(stage0)
    MLIR.Module.destroy(native)
  end

  @tag :tmp_dir
  @tag timeout: 180_000
  test "Batata AOT ex.add kernel fails before conversion on target drift", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Build.build_ex_add!(tmp_dir, ctx, build_options())
    module = input_module(ctx)

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
  test "Batata compiler-kernel build rejects unknown policy", %{ctx: ctx, tmp_dir: tmp_dir} do
    assert_raise ArgumentError, ~r/unknown compiler-kernel build options/, fn ->
      Build.build_ex_add!(tmp_dir, ctx, Keyword.put(build_options(), :fallback, :stage0))
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
        capabilities: ["ir.scalar.v1", "pattern.register"]
      ]
    )
  end

  defp input_module(ctx) do
    MLIR.Module.create!(
      ~s[module { func.func @add(%a: i64, %b: i64) -> i64 { %0 = "ex.add"(%a, %b) : (i64, i64) -> i64 func.return %0 : i64 } }],
      ctx: ctx
    )
  end

  defp build_options do
    [
      compiler_revision: "batata-stage1-fixture",
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
