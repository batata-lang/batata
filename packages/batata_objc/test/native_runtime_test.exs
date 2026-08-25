defmodule Batata.ObjC.NativeRuntimeTest do
  use ExUnit.Case, async: true

  alias Batata.ObjC

  @tag :native
  test "builds a receipted host adapter", %{test: test} do
    output = Path.join(System.tmp_dir!(), "#{test}-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(output) end)

    plan = ObjC.appkit_plan(__MODULE__)
    artifact = ObjC.build_runtime(plan, output)

    assert File.regular?(artifact.archive)
    assert File.read!(artifact.binding_plan) == ObjC.canonical_json(plan)

    receipt = artifact.platform_receipt |> File.read!() |> JSON.decode!()
    assert receipt["binding_plan_digest"] == ObjC.digest(plan)
    assert receipt["target"] == plan.target
    assert receipt["zig"] == "0.16.0"
    assert receipt["archive"]["sha256"] =~ ~r/^[0-9a-f]{64}$/

    effects = artifact.memory_effects |> File.read!() |> JSON.decode!()
    assert Enum.any?(effects, &(&1["escape"] == "caller_must_root_argument"))
    assert Enum.any?(effects, &(&1["allocation"] == "transfer_owned"))
  end
end
