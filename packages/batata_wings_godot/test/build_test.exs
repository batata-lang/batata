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

    @tag :editor_replay
    @tag :tmp_dir
    test "pinned Godot editor replays and verifies the transactional final surface", %{
      tmp_dir: tmp_dir
    } do
      ctx = Context.create()
      on_exit(fn -> Context.destroy(ctx) end)

      output = WingsGodot.build_editor_replay!(tmp_dir, ctx)
      receipt = output.editor_receipt |> File.read!() |> JSON.decode!()

      assert receipt["operation"] ==
               "native_pick_move_region_individual_extrude_inset_bevel_history"

      assert length(receipt["steps"]) == 12
      assert receipt["godot_api_version"] == "4.6.2"
      assert receipt["differential"]["matched"]
      assert receipt["differential"]["before_state_code"] == 0
      assert receipt["differential"]["after_state_code"] == 7_127_800
      assert receipt["topology"]["after"]["closed"]
      assert receipt["topology"]["after"]["vertices"] == 24
      assert receipt["topology"]["after"]["edges"] == 44
      assert receipt["topology"]["after"]["faces"] == 22
      assert receipt["native_source"]["source_sha256"] == receipt["source_sha256"]
      assert receipt["event_schema"]["schema_version"] == 1
      assert receipt["selected_triangle_indices"] != []

      assert receipt["portable_state"]["replacement_policy"] ==
               "deep_export_then_atomic_replace"

      assert receipt["allocation"]["estimate_bytes"] <= receipt["allocation"]["quota_bytes"]
      assert "editor_move/6" in receipt["functions"]
      assert "editor_extrude/4" in receipt["functions"]
      assert "editor_extrude_individual/4" in receipt["functions"]
      assert "editor_inset/4" in receipt["functions"]
      assert "editor_bevel/5" in receipt["functions"]
      assert "editor_undo/2" in receipt["functions"]
      assert "editor_redo/2" in receipt["functions"]

      assert Enum.map(receipt["identity_delta"], & &1["operation"]) == [
               "region_extrude",
               "individual_extrude",
               "inset",
               "bevel"
             ]

      assert receipt["diagnostics"]["-3"]["code"] ==
               "E_WINGS_NATIVE_MEMORY_QUOTA_EXCEEDED"

      assert File.read!(Path.join(tmp_dir, ".batata/editor-plugin-ready")) == "ready"

      assert File.read!(Path.join(tmp_dir, "project.godot")) =~
               "res://addons/batata_wings_editor/plugin.cfg"

      assert File.regular?(output.library)
      assert Path.wildcard(Path.join(tmp_dir, "**/*.zig"), match_dot: true) == []
    end
  else
    test "unsupported hosts fail through the existing closed platform table" do
      assert_raise Diagnostic, fn -> WingsGodot.build_cube!("unused", :unused) end
    end
  end
end
