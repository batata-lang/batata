defmodule Batata.ObjC.ApplicationPlanTest.Application do
  use Batata.ObjC.AppKit.Application,
    name: "BatataHello",
    bundle_identifier: "org.batata.Hello"

  appkit_window(title: "Batata AppKit", frame: {100, 100, 480, 280})
  appkit_label(text: "Ready", frame: {40, 170, 400, 40})
  appkit_button(title: "Run Batata", frame: {140, 80, 200, 48}, action: :button_pressed)

  def did_finish_launching, do: 0
  def button_pressed, do: 0
  def should_terminate, do: true
end

defmodule Batata.ObjC.ApplicationPlanTest do
  use ExUnit.Case, async: true

  alias Batata.ObjC
  alias Batata.ObjC.AppKit.ApplicationPlan
  alias Batata.ObjC.ApplicationPlanTest.Application

  test "embeds one deterministic AppKit vertical slice" do
    plan = ObjC.application_plan(Application)

    assert plan.name == "BatataHello"
    assert plan.window.frame == {100.0, 100.0, 480.0, 280.0}
    assert plan.button.action == :button_pressed
    assert plan.callbacks.button_pressed == Batata.Symbol.function(:button_pressed, 0)
    assert ApplicationPlan.digest(plan) =~ ~r/^[0-9a-f]{64}$/
  end
end
