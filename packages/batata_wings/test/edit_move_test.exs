defmodule Batata.Wings.EditMoveTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.{Diagnostic, EditCommand, Editor, EditorState, Primitive, Topology}
  alias Batata.Wings.Topology.Build

  test "moving one selected face commits atomically with stable identities" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1])
    command = command(state, :move, %{"vector" => [0.0, 0.0, 1.0]})
    {moved, result} = Editor.execute!(state, command)

    assert moved.geometry_generation == 1
    assert moved.selection.face_ids == [1]
    assert moved.selection.revision == 0
    assert result.changed
    assert result.id_remap.vertices[4] == [4]
    assert moved.mesh.vertices[4] == {-1.0, -1.0, 2.0}
    assert moved.mesh.vertices[0] == {-1.0, -1.0, -1.0}
    assert Topology.stats(Build.build!(moved.mesh))["euler_characteristic"] == 2
    assert result.receipt["before_mesh_digest"] == Batata.Wings.digest(state.mesh)
    assert result.receipt["after_mesh_digest"] == Batata.Wings.digest(moved.mesh)
  end

  test "shared vertices move once and normal mode follows selected face normals" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1, 3])
    {moved, _result} = Editor.execute!(state, command(state, :move, %{"vector" => [1, 0, 0]}))

    assert moved.mesh.vertices[5] == {2.0, -1.0, 1.0}

    normal_state = EditorState.new!(Primitive.cube(), face_ids: [1])

    {normal_moved, _result} =
      Editor.execute!(normal_state, command(normal_state, :move, %{"normal_distance" => 0.5}))

    assert normal_moved.mesh.vertices[4] == {-1.0, -1.0, 1.5}
  end

  test "zero move is a generation-preserving no-op" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1])
    {same, result} = Editor.execute!(state, command(state, :move, %{"vector" => [0, 0, 0]}))

    assert same.geometry_generation == 0
    assert same.mesh == state.mesh
    refute result.changed
  end

  test "stale generation and insufficient quota fail without a candidate commit" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1])

    stale = EditCommand.new!(:move, %{"vector" => [0, 0, 1]}, Batata.Wings.digest(state.mesh), 1)

    error = assert_raise Diagnostic, fn -> Editor.execute!(state, stale) end
    assert error.code == "E_WINGS_EDIT_GENERATION_STALE"

    quota = command(state, :move, %{"vector" => [0, 0, 1]}, quota_bytes: 1)
    error = assert_raise Diagnostic, fn -> Editor.execute!(state, quota) end
    assert error.code == "E_WINGS_EDIT_MEMORY_QUOTA_EXCEEDED"
    assert Batata.Wings.digest(state.mesh) == quota.source_mesh_digest
  end

  test "selection transactions do not advance geometry generation" do
    state = EditorState.new!(Primitive.cube())

    {selected, result} =
      Editor.execute!(state, command(state, :select, %{"mode" => "add", "face_ids" => [1]}))

    assert selected.geometry_generation == 0
    assert selected.selection_revision == 1
    assert selected.selection.face_ids == [1]
    assert result.changed
    assert result.receipt["before_mesh_digest"] == result.receipt["after_mesh_digest"]
  end

  defp command(state, operation, arguments, options \\ []) do
    EditCommand.new!(
      operation,
      arguments,
      Batata.Wings.digest(state.mesh),
      state.geometry_generation,
      options
    )
  end
end
