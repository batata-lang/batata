defmodule Batata.Jason.Probe do
  @moduledoc """
  Owns the immutable Jason source pin, baselines, semantic gates, and reports.

  The package reports separate raw inventory and multi-level coverage evidence;
  it never turns a later compiler failure into an accepted frontend result.
  """

  alias Batata.Probe.Corpus
  alias Batata.Probe.Coverage

  @doc "Returns an absolute path to a packaged probe asset."
  @spec asset!(Path.t()) :: Path.t()
  def asset!(relative) do
    path = Application.app_dir(:batata_jason, Path.join("priv/probe", relative))

    if File.regular?(path), do: path, else: raise(ArgumentError, "unknown Jason probe asset")
  end

  @doc "Runs the raw and coverage probes once against an unmodified Jason checkout."
  @spec run!(Path.t(), keyword()) :: %{raw: map(), coverage: map()}
  def run!(source, opts \\ []) do
    report = Keyword.get(opts, :report, "_build/jason_probe/report.json")
    coverage = Keyword.get(opts, :coverage, "_build/jason_probe/coverage.json")
    fail_on_regression = Keyword.get(opts, :fail_on_regression, false)
    compile_link_concurrency = Keyword.get(opts, :compile_link_concurrency, 1)
    compile_link_profile = Keyword.get(opts, :compile_link_profile)
    qualified_only = Keyword.get(opts, :qualified_only, false)

    raw =
      Corpus.run!(source,
        name: "Jason",
        output: report,
        metadata: asset!("source.json"),
        baseline: asset!("baseline.json"),
        fail_on_regression: fail_on_regression
      )

    dashboard =
      Coverage.run!(
        [
          coverage_config(
            source,
            report,
            compile_link_concurrency,
            compile_link_profile,
            qualified_only
          )
        ],
        coverage,
        fail_on_regression: fail_on_regression
      )

    %{raw: raw, coverage: dashboard}
  end

  defp coverage_config(
         source,
         report,
         compile_link_concurrency,
         compile_link_profile,
         qualified_only
       ) do
    %{
      name: "jason",
      source: source,
      raw_report: report,
      baseline: asset!("baseline.json"),
      canonical_baseline: asset!("canonical.json"),
      link_baseline: asset!("link.json"),
      metadata: asset!("source.json"),
      capabilities: asset!("capabilities.json"),
      compile_link_options: [
        max_concurrency: compile_link_concurrency,
        profile_output: compile_link_profile,
        diagnose_isolated: not qualified_only
      ]
    }
  end
end
