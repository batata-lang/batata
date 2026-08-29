defmodule Mix.Tasks.Batata.Jason.Probe do
  @moduledoc false

  use Mix.Task

  alias Batata.Jason.Probe

  @shortdoc "Builds raw and coverage evidence for pinned Jason"
  @switches [
    source: :string,
    report: :string,
    coverage: :string,
    fail_on_regression: :boolean,
    compile_link_concurrency: :integer,
    compile_link_profile: :string,
    qualified_only: :boolean,
    execute_unmodified: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("unexpected Jason probe arguments")
    end

    source = Keyword.get(opts, :source) || Mix.raise("--source is required")

    Probe.run!(source,
      report: Keyword.get(opts, :report, "_build/jason_probe/report.json"),
      coverage: Keyword.get(opts, :coverage, "_build/jason_probe/coverage.json"),
      fail_on_regression: Keyword.get(opts, :fail_on_regression, false),
      compile_link_concurrency: Keyword.get(opts, :compile_link_concurrency, 1),
      compile_link_profile: Keyword.get(opts, :compile_link_profile),
      qualified_only: Keyword.get(opts, :qualified_only, false),
      execute_unmodified: Keyword.get(opts, :execute_unmodified, true)
    )
  end
end
