defmodule Batata.Memory.CalibrationTest do
  use ExUnit.Case, async: true

  alias Batata.Memory.{Bound, Calibration, Plan}

  test "accepts telemetry within both the proof and physical runtime limit" do
    plan = plan(4_096)

    assert {:ok, report} =
             Calibration.compare(plan, %{
               "arena_high_water_bytes" => 2_048,
               "arena_limit_bytes" => 4_096,
               "oom" => false,
               "typed_failure" => nil
             })

    assert report["status"] == "matched"
    assert report["proved_maximum_bytes"] == 4_096
    assert String.starts_with?(report["plan_hash"], "sha256:")
  end

  test "fails closed when runtime telemetry contradicts the proof" do
    plan = plan(4_096)

    telemetry = %{
      "arena_high_water_bytes" => 4_104,
      "arena_limit_bytes" => 4_096,
      "oom" => true,
      "typed_failure" => nil
    }

    assert {:error, report} = Calibration.compare(plan, telemetry)
    assert report["status"] == "contradiction"

    assert_raise Calibration.Error, fn ->
      Calibration.compare!(plan, telemetry)
    end
  end

  defp plan(maximum) do
    Plan.new!(
      policy: :report,
      source_hash: hash("source"),
      compiler_version: "0.1.0",
      dependency_lock: hash("lock"),
      maximum_memory: Bound.constant(maximum),
      runtime_limits: [
        %{
          "effective_bytes" => Integer.to_string(maximum),
          "enforcement" => "native-runtime",
          "hard_limit_bytes" => "67108864",
          "id" => "execution-arena",
          "scope" => "per-runtime-execution"
        }
      ]
    )
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
