defmodule Batata.ObjC.AppKitBuildTest.Application do
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

defmodule Batata.ObjC.AppKitBuildTest do
  use ExUnit.Case, async: false

  alias Batata.ObjC
  alias Batata.ObjC.AppKitBuildTest.Application
  alias Batata.ObjC.Platform
  alias Beaver.MLIR.Context

  @moduletag :appkit
  @moduletag :darwin
  @moduletag timeout: 180_000

  @tag :tmp_dir
  test "launches a real AppKit delegate and target-action loop", %{tmp_dir: tmp_dir} do
    ctx = Context.create()
    on_exit(fn -> Context.destroy(ctx) end)

    output =
      ObjC.build_app(
        """
        defmodule AppKitLoadSmoke do
          def main(), do: 0
          def did_finish_launching(), do: 0
          def button_pressed(), do: 0
          def should_terminate(), do: true
        end
        """,
        Application,
        tmp_dir,
        ctx,
        smoke: true
      )

    assert File.dir?(output.app)
    assert File.regular?(output.executable)
    assert File.read!(output.info_plist) =~ "org.batata.Hello"

    receipt = output.receipt |> File.read!() |> JSON.decode!()
    assert receipt["smoke"]
    assert receipt["target"] == Platform.host!().target
    assert length(receipt["artifacts"]) == 4
  end
end
