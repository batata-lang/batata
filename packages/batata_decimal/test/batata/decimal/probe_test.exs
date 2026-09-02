defmodule Batata.Decimal.ProbeTest do
  use ExUnit.Case, async: true

  alias Batata.Decimal.Probe

  test "owns the fail-closed Decimal baselines" do
    metadata = "source.json" |> Probe.asset!() |> File.read!() |> JSON.decode!()
    baseline = "baseline.json" |> Probe.asset!() |> File.read!() |> JSON.decode!()
    link = "link.json" |> Probe.asset!() |> File.read!() |> JSON.decode!()

    assert baseline["schema_version"] == 6
    assert baseline["summary"]["blockers"] == 37
    assert baseline["summary"]["definitions"] == 245
    assert baseline["summary"]["categories"]["alias"] == nil
    assert link["corpus"]["commit"] == metadata["commit"]
    assert link["runtime_slice"] == %{"removed_definition_count" => 0}
    assert link["unresolved_internal_dependencies"] == 7

    assert link["unit_attempt"] == %{
             "fingerprint" => "9f3d375153778f707ea641c0a0a3ffebc546c791c6dc53e96e7a432ef632c7e3",
             "reason_class" => "lowering_pass_failure",
             "status" => "lowering_failure"
           }
  end

  @tag :tmp_dir
  test "reuses raw inventory while emitting raw and coverage artifacts", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "decimal")
    File.mkdir_p!(Path.join(source, "lib"))

    File.write!(
      Path.join(source, "lib/sample.ex"),
      "defmodule Decimal.Sample do\n  def main(), do: 1\nend\n"
    )

    report = Path.join(tmp_dir, "artifacts/raw.json")
    coverage = Path.join(tmp_dir, "artifacts/coverage.json")

    assert %{raw: raw, coverage: dashboard} =
             Probe.run!(source, report: report, coverage: coverage)

    assert raw["corpus"]["name"] == "decimal"
    assert Map.has_key?(dashboard["corpora"], "decimal")
    assert File.regular?(report)
    assert File.regular?(coverage)
  end
end
