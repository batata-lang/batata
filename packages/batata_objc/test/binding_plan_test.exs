defmodule Batata.ObjC.BindingPlanTest do
  use ExUnit.Case, async: true

  alias Batata.ObjC.{BindingPlan, Diagnostic, Metadata}

  test "builds a deterministic closed AppKit plan" do
    plan = BindingPlan.new!(__MODULE__, Metadata.load!(), target: "aarch64-macos")
    replay = BindingPlan.new!(__MODULE__, Metadata.load!(), target: "aarch64-macos")

    assert plan.frameworks == ["AppKit", "Foundation"]
    assert Enum.any?(plan.classes, &(&1.name == "NSApplication" and &1.thread == :main))
    assert Enum.any?(plan.callbacks, &(&1.selector == "applicationDidFinishLaunching:"))
    assert BindingPlan.canonical_json(plan) == BindingPlan.canonical_json(replay)
    assert BindingPlan.digest(plan) == BindingPlan.digest(replay)
    assert BindingPlan.digest(plan) =~ ~r/^[0-9a-f]{64}$/
  end

  test "rejects unknown target before native build" do
    assert_raise Diagnostic, ~r/E_OBJC_TARGET_UNSUPPORTED/, fn ->
      BindingPlan.new!(__MODULE__, Metadata.load!(), target: "wasm32-wasi")
    end
  end

  test "rejects unknown descriptor fields" do
    manifest = Metadata.load!()
    [selector | rest] = manifest["selectors"]
    manifest = put_in(manifest["selectors"], [Map.put(selector, "escape_hatch", true) | rest])

    error =
      assert_raise Diagnostic, fn ->
        BindingPlan.new!(__MODULE__, manifest, target: "aarch64-macos")
      end

    assert error.code == "E_OBJC_METADATA_INCOMPLETE"
    assert "escape_hatch" in error.context.unknown
  end

  test "rejects unknown type encodings" do
    manifest = Metadata.load!()
    [selector | rest] = manifest["selectors"]
    manifest = put_in(manifest["selectors"], [Map.put(selector, "returns", "union") | rest])

    error =
      assert_raise Diagnostic, fn ->
        BindingPlan.new!(__MODULE__, manifest, target: "aarch64-macos")
      end

    assert error.code == "E_OBJC_TYPE_ENCODING_UNSUPPORTED"
  end
end
