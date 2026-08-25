defmodule Batata.Memory.ArtifactsTest do
  use Batata.Case, async: true

  alias Batata.Memory

  @moduletag timeout: 180_000

  @tag :tmp_dir
  test "report-mode AOT emits canonical replayable artifacts but no receipt", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    source = """
    defmodule MemoryArtifactSample do
      def main(), do: {1, 2}
    end
    """

    output = Batata.build(source, tmp_dir, ctx, memory_policy: :report)

    assert output.memory_plan == Memory.Artifacts.plan_path(tmp_dir)
    assert output.memory_diagnostics == Memory.Artifacts.diagnostics_path(tmp_dir)

    plan_json = File.read!(output.memory_plan)
    diagnostics_json = File.read!(output.memory_diagnostics)
    plan = JSON.decode!(plan_json)
    diagnostics = JSON.decode!(diagnostics_json)

    assert plan_json == Memory.canonical_json(plan) <> "\n"
    assert diagnostics_json == Memory.canonical_json(diagnostics) <> "\n"
    assert plan["policy"] == "report"
    assert plan["obligations"] != []
    assert diagnostics["diagnostics"] != []
    assert diagnostics["plan_hash"] == Memory.digest(plan)

    index = output.artifact_index |> File.read!() |> JSON.decode!()
    indexed = Enum.map(index["files"], & &1["path"])
    assert "memory-plan.json" in indexed
    assert "memory-diagnostics.json" in indexed

    refute File.exists?(Path.join(tmp_dir, "memory-receipt.json"))
    refute Enum.any?(File.ls!(tmp_dir), &String.contains?(&1, "receipt"))
  end

  @tag :tmp_dir
  test "strict mode fails before Lower and before creating its output directory", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output_dir = Path.join(tmp_dir, "strict-output")

    assert_raise Batata.Memory.DiagnosticError, fn ->
      Batata.build(
        "defmodule StrictMemory do\n def main(), do: {1, 2}\nend",
        output_dir,
        ctx,
        memory_policy: :strict
      )
    end

    refute File.exists?(output_dir)
  end
end
