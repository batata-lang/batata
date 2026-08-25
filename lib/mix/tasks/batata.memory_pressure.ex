defmodule Mix.Tasks.Batata.MemoryPressure do
  @shortdoc "Runs a deterministic native memory-pressure workload"

  @moduledoc """
  Runs one selected native pressure workload and writes a canonical replay artifact.

      mix batata.memory_pressure --workload quota-boundary \
        --quota-bytes 65536 --iterations 4097 --seed 263 \
        --output _build/memory_pressure/report.json
  """

  use Mix.Task

  alias Batata.Memory.Pressure

  @switches [
    workload: :string,
    quota_bytes: :integer,
    iterations: :integer,
    seed: :integer,
    output: :string
  ]

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [],
      do: Mix.raise("invalid arguments: #{inspect(positional ++ invalid)}")

    artifact = Pressure.run!(opts)
    snapshot = artifact["native_snapshot"]

    Mix.shell().info(
      "#{snapshot["workload"]}: #{artifact["status"]}; " <>
        "high_water=#{snapshot["arena_high_water_bytes"]}/#{snapshot["quota_bytes"]}; " <>
        "oom=#{snapshot["oom"]}"
    )
  end
end
