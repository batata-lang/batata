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
    assert is_boolean(artifact["native_snapshot"]["rss_available"])
    assert artifact["replay_env"]["BATATA_PRESSURE_WORKLOAD"] == "quota-boundary"
    assert artifact["hashes"]["term_runtime"] =~ "sha256:"
    assert File.read!(output) == Batata.Memory.canonical_json(artifact) <> "\n"
    assert File.exists?(output <> ".log")
  end

  test "rejects unknown workloads before invoking Zig" do
    assert_raise ArgumentError, ~r/workload must be one of/, fn ->
      Pressure.run!(workload: "unknown")
    end
  end

  @tag :tmp_dir
  test "closes reset, portable transfer, and multi-runtime lifecycles", %{tmp_dir: tmp_dir} do
    expectations = %{
      "reset-reuse" => %{
        "arena_capacity_growth_bytes" => 0,
        "resets" => 3,
        "runtime_count" => 1
      },
      "export-import" => %{
        "exports" => 2,
        "imports" => 1,
        "pin_reset_rejections" => 2,
        "post_pin_resets" => 1,
        "retained_exported_final_bytes" => 0,
        "runtime_count" => 2,
        "source_runtime_destroyed" => true
      },
      "multi-runtime" => %{"runtime_count" => 4}
    }

    Enum.each(expectations, fn {workload, expected} ->
      artifact =
        Pressure.run!(
          workload: workload,
          quota_bytes: 65_536,
          iterations: 64,
          cycles: 3,
          runtimes: if(workload == "multi-runtime", do: 4, else: 2),
          workers: if(workload == "reset-reuse", do: 8, else: 1),
          seed: 263,
          output: Path.join(tmp_dir, "#{workload}.json")
        )

      snapshot = artifact["native_snapshot"]
      assert snapshot["lifecycle_closed"]
      assert snapshot["arena_high_water_bytes"] <= 65_536
      Enum.each(expected, fn {key, value} -> assert snapshot[key] == value end)
    end)
  end
end
