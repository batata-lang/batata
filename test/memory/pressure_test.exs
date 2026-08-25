defmodule Batata.Memory.PressureTest do
  use ExUnit.Case, async: false

  alias Batata.Memory.Pressure

  @tag :tmp_dir
  test "writes a canonical replay artifact for a selected quota boundary", %{tmp_dir: tmp_dir} do
    output = Path.join(tmp_dir, "pressure.json")

    artifact =
      Pressure.run!(
        workload: "quota-boundary",
        quota_bytes: 4_096,
        iterations: 257,
        seed: 263,
        output: output
      )

    assert artifact["schema"] == "batata-memory-pressure/1"
    assert artifact["status"] == "passed"
    assert artifact["native_snapshot"]["oom"]
    assert artifact["native_snapshot"]["arena_high_water_bytes"] == 4_096
    assert artifact["replay_env"]["BATATA_PRESSURE_WORKLOAD"] == "quota-boundary"
    assert File.read!(output) == Batata.Memory.canonical_json(artifact) <> "\n"
    assert File.exists?(output <> ".log")
  end

  test "rejects unknown workloads before invoking Zig" do
    assert_raise ArgumentError, ~r/workload must be one of/, fn ->
      Pressure.run!(workload: "unknown")
    end
  end
end
