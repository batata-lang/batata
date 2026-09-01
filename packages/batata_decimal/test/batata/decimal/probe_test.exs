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
             "fingerprint" => "0f4d2f12f7bc7365eb93c3e70b95d053ee2a17b6795bf29934be277b9cbd8c60",
             "reason_class" => "multi_clause_trailing_literal_pattern",
             "status" => "frontend_normalization_failure"
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
