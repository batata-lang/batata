defmodule Mix.Tasks.Batata.Coverage.Merge do
  @moduledoc false

  use Mix.Task

  alias Batata.Probe.Coverage

  @shortdoc "Merges precomputed Batata corpus coverage dashboards"

  @switches [input: :string, output: :string]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("unexpected coverage merge arguments")
    end

    inputs = Keyword.get_values(opts, :input)
    output = Keyword.get(opts, :output, "_build/coverage/report.json")

    if inputs == [] do
      Mix.raise("at least one --input is required")
    end

    Coverage.merge!(inputs, output)
    Mix.shell().info("coverage dashboard -> #{output}")
  end
end
