defmodule Mix.Tasks.Batata.Decimal.Probe do
  @moduledoc false

  use Mix.Task

  alias Batata.Decimal.Probe

  @shortdoc "Builds raw and coverage evidence for pinned Decimal"
  @switches [
    source: :string,
    report: :string,
    coverage: :string,
    fail_on_regression: :boolean,
    compile_link_concurrency: :integer
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("unexpected Decimal probe arguments")
    end

    source = Keyword.get(opts, :source) || Mix.raise("--source is required")

    Probe.run!(source,
      report: Keyword.get(opts, :report, "_build/decimal_probe/report.json"),
      coverage: Keyword.get(opts, :coverage, "_build/decimal_probe/coverage.json"),
      fail_on_regression: Keyword.get(opts, :fail_on_regression, false),
      compile_link_concurrency: Keyword.get(opts, :compile_link_concurrency, 1)
    )
  end
end
