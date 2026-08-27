defmodule Batata.Jason.ProbeTest do
  use ExUnit.Case, async: true

  alias Batata.Jason.Probe

  test "owns the immutable Jason pin and fail-closed baselines" do
    metadata = "source.json" |> Probe.asset!() |> File.read!() |> JSON.decode!()
    baseline = "baseline.json" |> Probe.asset!() |> File.read!() |> JSON.decode!()
    link = "link.json" |> Probe.asset!() |> File.read!() |> JSON.decode!()

    assert metadata == %{
             "name" => "jason",
             "repository" => "https://github.com/michalmuskala/jason.git",
             "ref" => "v1.4.5",
             "commit" => "4ede42858eb19f80ec9e863aab52df466eab8608"
           }

    assert baseline["schema_version"] == 6
    assert baseline["summary"]["blockers"] == 66
    assert baseline["summary"]["definitions"] == 241
    assert baseline["summary"]["categories"]["alias"] == nil
    assert link["corpus"]["commit"] == metadata["commit"]
    assert link["runtime_slice"] == %{"removed_definition_count" => 20}
    assert link["unresolved_internal_dependencies"] == 14
  end

  @tag :tmp_dir
  test "reuses raw inventory while emitting raw and coverage artifacts", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "jason")
    File.mkdir_p!(Path.join(source, "lib"))

    File.write!(
      Path.join(source, "lib/sample.ex"),
      "defmodule Jason.Sample do\n  def main(), do: 1\nend\n"
    )

    report = Path.join(tmp_dir, "artifacts/raw.json")
    coverage = Path.join(tmp_dir, "artifacts/coverage.json")
    profile = Path.join(tmp_dir, "artifacts/compile-link-profile.json")

    assert %{raw: raw, coverage: dashboard} =
             Probe.run!(source,
               report: report,
               coverage: coverage,
               compile_link_profile: profile,
               qualified_only: true
             )

    assert raw["corpus"]["name"] == "jason"
    assert Map.has_key?(dashboard["corpora"], "jason")
    assert File.regular?(report)
    assert File.regular?(coverage)
    assert File.regular?(profile)

    current = dashboard["corpora"]["jason"]["corpus_compile_link"]["current"]
    assert current["isolated_attempts"] == "omitted"
    assert current["attempts"] == []
  end
end
