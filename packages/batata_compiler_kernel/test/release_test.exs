defmodule Batata.CompilerKernel.ReleaseTest do
  use ExUnit.Case, async: false

  alias Batata.CompilerKernel.Release
  alias Beaver.MLIR
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest
  alias Beaver.MLIR.Dialect.Ex, as: ExDialect

  @beaver_revision "94e4b8610d9b9c4f9146c4e820f25725b5d51e33"

  setup do
    ctx = MLIR.Context.create()
    MLIR.Context.allow_unregistered_dialects(ctx)
    on_exit(fn -> MLIR.Context.destroy(ctx) end)
    %{ctx: ctx}
  end

  @tag :tmp_dir
  @tag timeout: 240_000
  test "builds a path-independent Stage 1/2 release index", %{ctx: ctx, tmp_dir: tmp_dir} do
    output = Release.build!(tmp_dir, ctx, release_options())

    assert File.regular?(output.stage1.library)
    assert File.regular?(output.stage2.library)
    assert File.regular?(output.index_path)
    assert File.regular?(output.performance_receipt)
    assert output.stage2.kernel_manifest.bootstrap["seed"] == "previous-native"

    assert output.index["production_kernel_identity"] ==
             KernelManifest.identity_digest(output.stage2.kernel_manifest)

    assert Enum.map(output.index["stages"], & &1["stage"]) == ~w(stage1 stage2)
    assert output.index["dialect_schema_digest"] == ExDialect.schema_digest()
    assert output.index["performance_receipt"]["callback_free"] == true
    assert output.index["performance_receipt"]["sizes"] == [4, 16]

    performance = output.performance_receipt |> File.read!() |> JSON.decode!()
    assert performance["callback_free"] == true

    for sample <- performance["samples"] do
      assert sample["stage0"]["beam"]["callback_count"] == 0
      assert sample["stage2"]["beam"]["callback_count"] == 0
      assert sample["stage0"]["status"] == "ok"
      assert sample["stage2"]["status"] == "ok"
    end

    bytes = File.read!(output.index_path)
    assert bytes == Batata.Memory.canonical_json(output.index) <> "\n"
    refute bytes =~ tmp_dir
  end

  @tag :tmp_dir
  test "rejects incomplete release identity before creating output", %{ctx: ctx, tmp_dir: tmp_dir} do
    output_dir = Path.join(tmp_dir, "release")

    assert_raise ArgumentError, ~r/missing compiler-kernel release options/, fn ->
      Release.build!(output_dir, ctx, compiler_revision: "batata-fixture")
    end

    refute File.exists?(output_dir)
  end

  defp release_options do
    [
      compiler_revision: "batata-release-fixture",
      beaver_revision: @beaver_revision,
      target: %{"triple" => "host-test", "cpu" => "generic", "features" => []},
      profile_sizes: [4, 16]
    ]
  end
end
