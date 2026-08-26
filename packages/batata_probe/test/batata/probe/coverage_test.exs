defmodule Batata.Probe.CoverageTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Coverage
  alias Batata.Probe.CoverageDashboard
  alias Batata.Probe.Report

  @tag :tmp_dir
  test "keeps raw, canonical, link, and semantic claims separate", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "corpus")
    File.mkdir_p!(Path.join(source, "lib"))

    File.write!(Path.join(source, "lib/sample.ex"), """
    defmodule Sample do
      def identity(value), do: value
    end
    """)

    metadata = Path.join(tmp_dir, "source.json")
    baseline = Path.join(tmp_dir, "baseline.json")
    capabilities = Path.join(tmp_dir, "capabilities.json")
    output = Path.join(tmp_dir, "coverage.json")

    source_metadata = %{
      "name" => "sample",
      "repository" => "https://example.invalid/sample.git",
      "ref" => "v1",
      "commit" => String.duplicate("a", 40)
    }

    File.write!(metadata, JSON.encode!(source_metadata))
    File.write!(baseline, JSON.encode!(Report.build(source, metadata: source_metadata)))

    File.write!(
      capabilities,
      JSON.encode!(%{
        "schema_version" => 1,
        "capabilities" => [
          %{"id" => "identity", "status" => "executable", "gate" => "coverage_test"},
          %{
            "id" => "later",
            "status" => "blocked",
            "owner" => "runtime",
            "reason" => "not implemented"
          }
        ]
      })
    )

    dashboard =
      Coverage.run!(
        [
          %{
            name: "sample",
            source: source,
            metadata: metadata,
            baseline: baseline,
            capabilities: capabilities,
            raw_report: baseline
          }
        ],
        output,
        fail_on_regression: true
      )

    assert dashboard == output |> File.read!() |> JSON.decode!()
    sample = dashboard["corpora"]["sample"]
    assert sample["raw_inventory"]["status"] == "preserved"
    assert sample["canonical_acceptance"]["status"] == "pass"
    assert sample["corpus_compile_link"]["status"] == "pass"
    assert sample["semantic_execution"]["status"] == "blocked"
    assert sample["semantic_execution"]["current"]["blocked_ids"] == ["later"]

    assert sample["claim"] ==
             "whole-corpus compile/link coverage; semantic execution is still required"
  end

  @tag :tmp_dir
  test "rejects silent raw blocker identity loss", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "corpus")
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "lib/sample.ex"), "defmodule Sample do\nend\n")

    report = Report.build(source)
    baseline = Path.join(tmp_dir, "baseline.json")
    metadata = Path.join(tmp_dir, "source.json")
    capabilities = Path.join(tmp_dir, "capabilities.json")

    File.write!(baseline, JSON.encode!(Map.put(report, "blockers", [%{"id" => "lost"}])))
    File.write!(metadata, JSON.encode!(%{"name" => "sample"}))
    File.write!(capabilities, JSON.encode!(%{"schema_version" => 1, "capabilities" => []}))

    assert_raise Mix.Error, ~r/raw blocker IDs disappeared/, fn ->
      Coverage.run!(
        [
          %{
            name: "sample",
            source: source,
            metadata: metadata,
            baseline: baseline,
            capabilities: capabilities
          }
        ],
        Path.join(tmp_dir, "coverage.json"),
        fail_on_regression: true
      )
    end
  end

  @tag :tmp_dir
  test "rejects canonical blocker regressions independently of raw inventory", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "corpus")
    File.mkdir_p!(Path.join(source, "lib"))

    File.write!(
      Path.join(source, "lib/sample.ex"),
      "defmodule Sample do\nimport Enum\ndef ok(), do: true\nend\n"
    )

    metadata = %{"name" => "sample"}
    report = Report.build(source, metadata: metadata)
    raw_baseline = Path.join(tmp_dir, "raw.json")
    canonical_baseline = Path.join(tmp_dir, "canonical.json")
    metadata_path = Path.join(tmp_dir, "source.json")
    capabilities = Path.join(tmp_dir, "capabilities.json")

    File.write!(raw_baseline, JSON.encode!(report))
    File.write!(metadata_path, JSON.encode!(metadata))
    File.write!(capabilities, JSON.encode!(%{"schema_version" => 1, "capabilities" => []}))

    File.write!(
      canonical_baseline,
      JSON.encode!(%{
        "schema_version" => 1,
        "corpus" => %{"name" => "sample", "ref" => nil, "commit" => nil},
        "failed_files" => 0,
        "unsupported_forms" => 0,
        "results" => [
          %{"path" => "lib/sample.ex", "unsupported_forms" => 0, "reasons" => %{}}
        ]
      })
    )

    assert_raise Mix.Error, ~r/canonical unsupported forms increased/, fn ->
      Coverage.run!(
        [
          %{
            name: "sample",
            source: source,
            metadata: metadata_path,
            baseline: raw_baseline,
            canonical_baseline: canonical_baseline,
            capabilities: capabilities,
            raw_report: raw_baseline
          }
        ],
        Path.join(tmp_dir, "coverage.json"),
        fail_on_regression: true
      )
    end
  end

  @tag :tmp_dir
  test "merges precomputed dashboards without corpus source access", %{tmp_dir: tmp_dir} do
    contract = %{
      "schema_version" => 2,
      "coverage_claim" =>
        "complete coverage requires canonical acceptance, whole-corpus compile/link, and oracle-backed semantic execution",
      "levels" => ~w(raw_inventory canonical_acceptance corpus_compile_link semantic_execution)
    }

    jason = Map.put(contract, "corpora", %{"jason" => %{"claim" => "jason evidence"}})
    decimal = Map.put(contract, "corpora", %{"decimal" => %{"claim" => "decimal evidence"}})
    jason_path = Path.join(tmp_dir, "jason.json")
    decimal_path = Path.join(tmp_dir, "decimal.json")
    output = Path.join(tmp_dir, "merged/report.json")
    File.write!(jason_path, JSON.encode!(jason))
    File.write!(decimal_path, JSON.encode!(decimal))

    assert %{"corpora" => corpora} =
             CoverageDashboard.merge!([jason_path, decimal_path], output)

    assert Map.keys(corpora) |> Enum.sort() == ["decimal", "jason"]
    assert JSON.decode!(File.read!(output))["corpora"] == corpora
  end

  @tag :tmp_dir
  test "rejects duplicate corpora while merging dashboards", %{tmp_dir: tmp_dir} do
    dashboard = %{
      "schema_version" => 2,
      "coverage_claim" =>
        "complete coverage requires canonical acceptance, whole-corpus compile/link, and oracle-backed semantic execution",
      "levels" => ~w(raw_inventory canonical_acceptance corpus_compile_link semantic_execution),
      "corpora" => %{"same" => %{}}
    }

    first = Path.join(tmp_dir, "first.json")
    second = Path.join(tmp_dir, "second.json")
    File.write!(first, JSON.encode!(dashboard))
    File.write!(second, JSON.encode!(dashboard))

    assert_raise ArgumentError, ~r/duplicate coverage corpus same/, fn ->
      CoverageDashboard.merge!([first, second], Path.join(tmp_dir, "merged.json"))
    end
  end
end
