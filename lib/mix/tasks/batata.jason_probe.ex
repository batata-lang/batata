defmodule Mix.Tasks.Batata.JasonProbe do
  @shortdoc "Inventories a pinned Jason source tree"

  @moduledoc """
  Generates a machine-readable report without adding Jason as a Batata or
  Beaver production dependency.

      mix batata.jason_probe --source /path/to/jason \
        --output _build/jason_probe/report.json

  Pass `--baseline probe/jason/baseline.json` to print a blocker diff. With
  `--fail-on-regression`, newly introduced blocker identities fail the task.
  """

  use Mix.Task

  alias Batata.Probe.Jason.{Diff, Report}

  @switches [
    source: :string,
    output: :string,
    metadata: :string,
    baseline: :string,
    fail_on_regression: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    source = opts[:source] || Mix.raise("--source is required")
    output = opts[:output] || "_build/jason_probe/report.json"
    metadata_path = opts[:metadata] || "probe/jason/source.json"
    metadata = Report.read_metadata!(metadata_path)
    report = Report.write!(source, output, metadata: metadata)

    Mix.shell().info(
      "Jason probe: #{report["summary"]["files"]} files, " <>
        "#{report["summary"]["blockers"]} blockers -> #{output}"
    )

    compare_baseline(report, opts)
  end

  defp compare_baseline(report, opts) do
    case opts[:baseline] do
      nil ->
        :ok

      path ->
        baseline = path |> File.read!() |> JSON.decode!()
        diff = Diff.compare(report, baseline)

        Mix.shell().info(
          "Jason probe diff: +#{length(diff["added"])} -#{length(diff["resolved"])}"
        )

        if opts[:fail_on_regression] and diff["regression"] do
          Mix.raise("Jason probe introduced #{length(diff["added"])} blocker(s)")
        end
    end
  end
end
