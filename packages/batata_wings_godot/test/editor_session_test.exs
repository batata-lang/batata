defmodule Batata.Wings.Godot.EditorSessionTest do
  use ExUnit.Case, async: true

  alias Batata.Godot.Diagnostic
  alias Batata.Wings.{EditorState, Primitive, Selection}
  alias Batata.Wings.Godot.{EditorInput, EditorSession}

  test "closed pointer input selects a canonical face without advancing geometry" do
    state = EditorState.new!(Primitive.cube())
    event = pointer_event(state)
    {selected, result} = EditorSession.handle!(state, event)

    assert selected.geometry_generation == 0
    assert selected.selection.face_ids == [1]
    assert selected.selection_revision == 1
    assert result.receipt["operation"] == "select"
    assert byte_size(EditorInput.digest(event)) == 64
  end

  test "stale and undeclared editor events fail closed" do
    state = EditorState.new!(Primitive.cube())

    stale = Map.put(pointer_event(state), "expected_generation", 1)
    error = assert_raise Diagnostic, fn -> EditorSession.handle!(state, stale) end
    assert error.code == "E_GODOT_EDITOR_STATE_STALE"
    assert error.context["before_mesh_digest"] == Batata.Wings.digest(state.mesh)

    unsupported = Map.put(pointer_event(state), "kind", "gesture")
    error = assert_raise Diagnostic, fn -> EditorSession.handle!(state, unsupported) end
    assert error.code == "E_GODOT_EDITOR_EVENT_UNSUPPORTED"
    assert state.selection == Selection.new!(state.mesh)
  end

  test "full editor replay restores the original and final mesh through history" do
    initial = EditorState.new!(Primitive.cube(), max_entries: 8)
    replay = EditorSession.replay!(initial)

    assert length(replay.steps) == 13
    assert replay.undo_digest == Batata.Wings.digest(initial.mesh)
    assert replay.final_digest == Batata.Wings.digest(replay.final.mesh)
    refute replay.final_digest == replay.undo_digest
    assert replay.final.selection.face_ids == [1]
    assert replay.final.geometry_generation == 12

    assert Enum.all?(replay.steps, fn step ->
             step["topology"]["closed"] and step["topology"]["euler_characteristic"] == 2
           end)
  end

  defp pointer_event(state) do
    %{
      "button" => "primary",
      "camera_ray" => %{"direction" => [0.0, 0.0, -1.0], "origin" => [0.0, 0.0, 5.0]},
      "expected_generation" => state.geometry_generation,
      "kind" => "pointer_button",
      "modifiers" => [],
      "position" => [640.0, 360.0],
      "pressed" => true
    }
  end
end
