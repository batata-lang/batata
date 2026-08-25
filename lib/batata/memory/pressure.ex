defmodule Batata.Memory.Pressure do
  @moduledoc "Runs deterministic native memory-pressure workloads and writes replay artifacts."

  alias Batata.Memory
  alias Batata.Memory.RuntimeQuota

  @workloads ~w(composite-arena quota-boundary)

  @spec run!(keyword()) :: map()
  def run!(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    workload = Keyword.get(opts, :workload, "composite-arena")
    seed = validate_integer!(Keyword.get(opts, :seed, 0x107), :seed, 0)
    iterations = validate_integer!(Keyword.get(opts, :iterations, 4_097), :iterations, 1)
    quota_bytes = opts |> Keyword.get(:quota_bytes, 65_536) |> RuntimeQuota.validate!()
    output = Keyword.get(opts, :output, Path.join(root, "_build/memory_pressure/report.json"))

    unless workload in @workloads,
      do:
        raise(
          ArgumentError,
          "workload must be one of #{inspect(@workloads)}, got: #{inspect(workload)}"
        )

    env = %{
      "BATATA_PRESSURE_ITERATIONS" => Integer.to_string(iterations),
      "BATATA_PRESSURE_QUOTA_BYTES" => Integer.to_string(quota_bytes),
      "BATATA_PRESSURE_SEED" => Integer.to_string(seed),
      "BATATA_PRESSURE_WORKLOAD" => workload
    }

    args = [
      "test",
      "--dep",
      "runtime",
      "-Mroot=native/memory_pressure_test.zig",
      "-Mruntime=native/term_runtime.zig",
      "-lc"
    ]

    {log, exit_code} =
      System.cmd(Keyword.get(opts, :zig, "zig"), args,
        cd: root,
        env: Enum.to_list(env),
        stderr_to_stdout: true
      )

    snapshot = parse_snapshot!(log)
    status = if exit_code == 0, do: "passed", else: "failed"

    artifact = %{
      "command" => ["zig" | args],
      "exit_code" => exit_code,
      "log_sha256" => sha256(log),
      "native_snapshot" => snapshot,
      "replay_env" => env,
      "schema" => "batata-memory-pressure/1",
      "status" => status,
      "toolchain" => %{"zig" => zig_version(Keyword.get(opts, :zig, "zig"))}
    }

    artifact = Map.put(artifact, "artifact_fingerprint", Memory.digest(artifact))
    write!(output, Memory.canonical_json(artifact) <> "\n")
    write!(output <> ".log", log)

    if exit_code != 0, do: raise("memory-pressure workload failed; replay artifact: #{output}")
    artifact
  end

  defp parse_snapshot!(log) do
    with [json] <- Regex.run(~r/BATATA_PRESSURE (\{[^\n]*\})/, log, capture: :all_but_first),
         {:ok, snapshot} <- JSON.decode(json) do
      snapshot
    else
      _ -> raise "native pressure log did not contain one BATATA_PRESSURE snapshot"
    end
  end

  defp validate_integer!(value, _name, minimum) when is_integer(value) and value >= minimum,
    do: value

  defp validate_integer!(value, name, minimum),
    do: raise(ArgumentError, "#{name} must be an integer >= #{minimum}, got: #{inspect(value)}")

  defp zig_version(zig) do
    case System.cmd(zig, ["version"], stderr_to_stdout: true) do
      {version, 0} -> String.trim(version)
      _ -> "unknown"
    end
  end

  defp sha256(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp write!(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
