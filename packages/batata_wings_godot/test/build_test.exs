defmodule Batata.Wings.Godot.BuildTest do
  use ExUnit.Case, async: false

  alias Batata.Godot.{Diagnostic, Platform}
  alias Batata.Wings.Godot, as: WingsGodot

  @supported_host (try do
                     Platform.host!()
                     true
                   rescue
                     Diagnostic -> false
                   end)

  if @supported_host do
    alias Beaver.MLIR.Context

    @moduletag timeout: 180_000

    @tag :tmp_dir
    test "Batata materialization creates and verifies the subdivided cube ArrayMesh", %{
      tmp_dir: tmp_dir
    } do
      ctx = Context.create()
      on_exit(fn -> Context.destroy(ctx) end)

      output = WingsGodot.build_cube!(tmp_dir, ctx)
      receipt = output.mesh_receipt |> File.read!() |> JSON.decode!()

      assert receipt["operation"] == "cube_catmull_clark_1_array_mesh"

      assert receipt["topology"] == %{
               "closed" => true,
               "edges" => 48,
               "euler_characteristic" => 2,
               "faces" => 24,
               "vertices" => 26
             }

      assert receipt["surface"]["triangle_count"] == 48
      assert receipt["godot_api_version"] == "4.6.2"
      assert byte_size(receipt["mesh_digest"]) == 64
      assert File.regular?(output.library)
      assert Path.wildcard(Path.join(tmp_dir, "**/*.zig"), match_dot: true) == []
    end
  else
    test "unsupported hosts fail through the existing closed platform table" do
      assert_raise Diagnostic, fn -> WingsGodot.build_cube!("unused", :unused) end
    end
  end
end
