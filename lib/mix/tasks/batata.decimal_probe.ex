defmodule Mix.Tasks.Batata.DecimalProbe do
  @shortdoc "Inventories a pinned Decimal source tree"

  @moduledoc """
  Generates a read-only, machine-readable report for Decimal without adding
  it as a Batata or Beaver production dependency.

      mix batata.decimal_probe --source /path/to/decimal
  """

  use Mix.Task

  alias Batata.Probe.Corpus

  @switches [source: :string, output: :string, metadata: :string, baseline: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    source = opts[:source] || Mix.raise("--source is required")

    Corpus.run!(source,
      name: "Decimal",
      output: opts[:output] || "_build/decimal_probe/report.json",
      metadata: opts[:metadata] || "probe/decimal/source.json",
      baseline: opts[:baseline]
    )
  end
end
