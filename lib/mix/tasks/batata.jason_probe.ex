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

  alias Batata.Probe.Corpus

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

    Corpus.run!(source,
      name: "Jason",
      output: output,
      metadata: opts[:metadata] || "probe/jason/source.json",
      baseline: opts[:baseline],
      fail_on_regression: opts[:fail_on_regression]
    )
  end
end
