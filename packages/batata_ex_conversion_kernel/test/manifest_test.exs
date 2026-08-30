defmodule Batata.ExConversionKernel.ManifestTest do
  use ExUnit.Case, async: true

  alias Batata.ExConversionKernel
  alias Batata.ExConversionKernel.Manifest
  alias Beaver.MLIR.Conversion.Kernel.Manifest, as: KernelManifest

  @digest "sha256:" <> String.duplicate("a", 64)

  @tag :tmp_dir
  test "builds a Batata-owned manifest with an auditable Stage 0 provenance", %{tmp_dir: tmp_dir} do
    artifact = Path.join(tmp_dir, "libbatata_ex_conversion.so")
    File.write!(artifact, "compiler-kernel-fixture")

    manifest = Manifest.build!(artifact, manifest_options())

    assert manifest.provider == ExConversionKernel.provider()
    assert manifest.runtime_abi_digest == Batata.TermRuntime.abi_digest()

    roots = Enum.map(manifest.patterns, & &1["root"])
    assert length(roots) == 158
    assert roots == Enum.sort(roots)

    assert MapSet.subset?(
             MapSet.new(~w(
                 ex.add ex.apply ex.binary ex.binary_part ex.call ex.cmp ex.div ex.func ex.func_addr
                 ex.box ex.if ex.is_atom ex.is_binary ex.is_float ex.is_integer
                 ex.is_list ex.is_map ex.is_tuple ex.list ex.lit ex.map ex.mul ex.rem ex.return
                 ex.make_fun ex.make_fun_with_arity ex.make_fun_with_signature ex.sub ex.term_eq
                 ex.to_word ex.try ex.tuple ex.unbox ex.var ex.yield
               )),
             MapSet.new(roots)
           )

    assert MapSet.subset?(
             MapSet.new(~w(
                 ex.runtime_create ex.runtime_enter ex.runtime_leave
                 ex.runtime_destroy ex.result_create ex.result_destroy
                 ex.result_root_kind ex.result_root_word
                 ex.result_exception_kind ex.result_exception_reason
                 ex.result_term_kind ex.result_atom_name
                 ex.result_term_length ex.result_term_get ex.term_export
                 ex.term_import ex.exported_clone ex.exported_destroy
                 ex.exported_length ex.exported_get ex.term_handle_export
                 ex.term_handle_destroy ex.process_table_reset
               )),
             MapSet.new(roots)
           )

    assert manifest.capabilities == [
             "ir.attribute.v1",
             "ir.region.v1",
             "ir.scalar.v1",
             "ir.symbol.v1",
             "ir.type.v1",
             "pattern.register"
           ]

    assert manifest.bootstrap == %{
             "stage" => "stage1",
             "seed" => "cpp-bootstrap",
             "provenance" => "beaver-stage0:sha256:fixture"
           }

    assert ^manifest = KernelManifest.verify_artifact!(manifest, artifact)
    assert KernelManifest.identity_digest(manifest) =~ ~r/^sha256:[0-9a-f]{64}$/
  end

  @tag :tmp_dir
  test "writes deterministic canonical sidecar JSON", %{tmp_dir: tmp_dir} do
    artifact = Path.join(tmp_dir, "libbatata_ex_conversion.so")
    File.write!(artifact, "compiler-kernel-fixture")
    manifest = Manifest.build!(artifact, manifest_options())

    sidecar = Manifest.write_sidecar!(manifest, tmp_dir)
    assert File.read!(sidecar) == KernelManifest.encode!(manifest)
    assert KernelManifest.decode!(File.read!(sidecar)) == manifest
  end

  test "ships a frozen, non-production Stage 0 seed policy" do
    seed = ExConversionKernel.seed_manifest!()
    assert seed["provider"] == "cpp-bootstrap"
    assert seed["entrypoint"] == "beaverPopulateExScalarConversionPatterns"

    assert seed["identity_digest"] ==
             "sha256:6e5d22d6e59047a2875c55104427a343affd23fdfd867a5d988fb34f15e64d4c"

    assert length(seed["patterns"]) == 12
  end

  test "rejects cwd-dependent artifact paths and implicit provenance" do
    assert_raise ArgumentError, ~r/existing absolute file/, fn ->
      Manifest.build!("kernel.so", manifest_options())
    end

    assert_raise KeyError, fn ->
      Manifest.build!(__ENV__.file, Keyword.delete(manifest_options(), :compiler_revision))
    end
  end

  defp manifest_options do
    [
      compiler_revision: "batata-fixture-revision",
      beaver_revision: "beaver-fixture-revision",
      dialect_schema_digest: @digest,
      runtime_abi_digest: Batata.TermRuntime.abi_digest(),
      target: %{"triple" => "host-test", "cpu" => "generic", "features" => []},
      bootstrap_provenance: "beaver-stage0:sha256:fixture"
    ]
  end
end
