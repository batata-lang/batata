defmodule Batata.Decimal.Probe do
  @moduledoc """
  Owns the immutable Decimal source pin, baselines, semantic gates, and reports.

  Raw inventory, canonical acceptance, compile/link, and semantic execution
  remain separate evidence levels so unsupported behavior fails closed.
  """

  alias Batata.Probe.Corpus
  alias Batata.Probe.Coverage

  @doc "Returns an absolute path to a packaged probe asset."
  @spec asset!(Path.t()) :: Path.t()
  def asset!(relative) do
    path = Application.app_dir(:batata_decimal, Path.join("priv/probe", relative))

    if File.regular?(path), do: path, else: raise(ArgumentError, "unknown Decimal probe asset")
  end

  @doc "Runs the raw and coverage probes against an unmodified Decimal checkout."
  @spec run!(Path.t(), keyword()) :: %{raw: map(), coverage: map()}
  def run!(source, opts \\ []) do
    report = Keyword.get(opts, :report, "_build/decimal_probe/report.json")
    coverage = Keyword.get(opts, :coverage, "_build/decimal_probe/coverage.json")
    fail_on_regression = Keyword.get(opts, :fail_on_regression, false)

    raw =
      Corpus.run!(source,
        name: "Decimal",
        output: report,
        metadata: asset!("source.json"),
        baseline: asset!("baseline.json"),
        fail_on_regression: fail_on_regression
      )

    dashboard =
      Coverage.run!(
        [coverage_config(source, report)],
        coverage,
        fail_on_regression: fail_on_regression
      )

    %{raw: raw, coverage: dashboard}
  end

  defp coverage_config(source, report) do
    %{
      name: "decimal",
      source: source,
      raw_report: report,
      baseline: asset!("baseline.json"),
      canonical_baseline: asset!("canonical.json"),
      link_baseline: asset!("link.json"),
      metadata: asset!("source.json"),
      capabilities: asset!("capabilities.json")
    }
  end
end
