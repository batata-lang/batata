defmodule Batata.Probe.Corpus do
  @moduledoc """
  Corpus-neutral orchestration for deterministic source inventory probes.

  The source-specific Mix tasks choose paths and labels while the existing
  inventory, report, and diff modules retain their established behaviour.
  """

  alias Batata.Probe.Jason.{Diff, Report}

  @spec run!(Path.t(), keyword()) :: map()
  def run!(source, opts) do
    name = Keyword.fetch!(opts, :name)
    output = Keyword.fetch!(opts, :output)
    metadata_path = Keyword.fetch!(opts, :metadata)
    metadata = Report.read_metadata!(metadata_path)
    report = Report.write!(source, output, metadata: metadata)

    Mix.shell().info(
      "#{name} probe: #{report["summary"]["files"]} files, " <>
        "#{report["summary"]["blockers"]} blockers -> #{output}"
    )

    compare_baseline(report, name, opts)
    report
  end

  defp compare_baseline(report, name, opts) do
    case opts[:baseline] do
      nil ->
        :ok

      path ->
        baseline = path |> File.read!() |> JSON.decode!()
        diff = Diff.compare(report, baseline)

        Mix.shell().info(
          "#{name} probe diff: +#{length(diff["added"])} -#{length(diff["resolved"])}"
        )

        if Keyword.get(opts, :fail_on_regression, false) and diff["regression"] do
          Mix.raise("#{name} probe introduced #{length(diff["added"])} blocker(s)")
        end
    end
  end
end
