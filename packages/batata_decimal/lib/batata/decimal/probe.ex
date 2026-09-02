defmodule Batata.Decimal.Probe do
  @moduledoc """
  Owns the immutable Decimal source pin, baselines, semantic gates, and reports.

  Raw inventory, canonical acceptance, compile/link, and semantic execution
  remain separate evidence levels so unsupported behavior fails closed.
  """

  alias Batata.Decimal.UnmodifiedExecution
  alias Batata.Probe.Corpus
  alias Batata.Probe.Coverage

  @doc "Returns an absolute path to a packaged probe asset."
  @spec asset!(Path.t()) :: Path.t()
  def asset!(relative) do
    path = Application.app_dir(:batata_decimal, Path.join("priv/probe", relative))

    if File.regular?(path), do: path, else: raise(ArgumentError, "unknown Decimal probe asset")
  end

  @doc "Runs the raw and coverage probes against an unmodified Decimal checkout."
  @spec run!(Path.t(), keyword()) :: %{raw: map(), coverage: map(), execution: map() | nil}
  def run!(source, opts \\ []) do
    report = Keyword.get(opts, :report, "_build/decimal_probe/report.json")
    coverage = Keyword.get(opts, :coverage, "_build/decimal_probe/coverage.json")
    fail_on_regression = Keyword.get(opts, :fail_on_regression, false)
    compile_link_concurrency = Keyword.get(opts, :compile_link_concurrency, 1)
    execute_unmodified = Keyword.get(opts, :execute_unmodified, true)

    raw =
      Corpus.run!(source,
        name: "Decimal",
        output: report,
        metadata: asset!("source.json"),
        baseline: asset!("baseline.json"),
        fail_on_regression: fail_on_regression
      )

    execution = if execute_unmodified, do: UnmodifiedExecution.run!(source)

    dashboard =
      Coverage.run!(
        [coverage_config(source, report, compile_link_concurrency, execution)],
        coverage,
        fail_on_regression: fail_on_regression
      )

    %{raw: raw, coverage: dashboard, execution: execution}
  end

  defp coverage_config(source, report, compile_link_concurrency, execution) do
    %{
      name: "decimal",
      source: source,
      raw_report: report,
      baseline: asset!("baseline.json"),
      canonical_baseline: asset!("canonical.json"),
      link_baseline: asset!("link.json"),
      metadata: asset!("source.json"),
      capabilities: asset!("capabilities.json"),
      semantic_evidence: execution,
      compile_link_options: [max_concurrency: compile_link_concurrency]
    }
  end
end
