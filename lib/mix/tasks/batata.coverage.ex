defmodule Mix.Tasks.Batata.Coverage do
  @shortdoc "Builds the pinned Jason and Decimal coverage dashboard"

  @moduledoc """
  Runs the raw inventory, canonical acceptance, compile/link contract, and
  semantic gate inventory for pinned Jason and Decimal source checkouts.

      mix batata.coverage \
        --jason-source /path/to/jason \
        --decimal-source /path/to/decimal \
        --output _build/coverage/report.json \
        --fail-on-regression
  """

  use Mix.Task

  alias Batata.Probe.Coverage

  @switches [
    jason_source: :string,
    decimal_source: :string,
    jason_raw_report: :string,
    decimal_raw_report: :string,
    output: :string,
    fail_on_regression: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")
    end

    corpora = [
      corpus("jason", required!(opts, :jason_source), opts[:jason_raw_report]),
      corpus("decimal", required!(opts, :decimal_source), opts[:decimal_raw_report])
    ]

    output = opts[:output] || "_build/coverage/report.json"

    dashboard =
      Coverage.run!(corpora, output,
        fail_on_regression: Keyword.get(opts, :fail_on_regression, false)
      )

    Enum.each(~w(jason decimal), fn name ->
      result = dashboard["corpora"][name]

      Mix.shell().info(
        "#{name}: #{result["claim"]}; " <>
          "canonical=#{result["canonical_acceptance"]["status"]}, " <>
          "link=#{result["corpus_compile_link"]["status"]}, " <>
          "semantics=#{result["semantic_execution"]["status"]}"
      )
    end)

    Mix.shell().info("coverage dashboard -> #{output}")
  end

  defp corpus(name, source, raw_report) do
    %{
      name: name,
      source: source,
      baseline: "probe/#{name}/baseline.json",
      canonical_baseline: "probe/#{name}/canonical.json",
      metadata: "probe/#{name}/source.json",
      capabilities: "probe/#{name}/capabilities.json",
      raw_report: raw_report
    }
  end

  defp required!(opts, key),
    do: opts[key] || Mix.raise("--#{key |> to_string() |> String.replace("_", "-")} is required")
end
