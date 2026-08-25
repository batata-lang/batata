defmodule Batata.Wings.HistoryTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.{Diagnostic, EditCommand, Editor, EditorState, Primitive, Selection}

  test "undo and redo restore exact mesh and selection identities with monotonic generations" do
    original = EditorState.new!(Primitive.cube(), face_ids: [1])

    {moved, _result} =
      Editor.execute!(original, command(original, :move, %{"vector" => [0, 0, 1]}))

    {extruded, _result} =
      Editor.execute!(
        moved,
        command(moved, :extrude, %{"mode" => "region", "distance" => 0.5, "direction" => "normal"})
      )

    final_mesh_digest = Batata.Wings.digest(extruded.mesh)
    selection_digest = Selection.digest(extruded.selection)

    {back_to_move, _result} = Editor.execute!(extruded, command(extruded, :undo, %{}))
    {back_to_cube, _result} = Editor.execute!(back_to_move, command(back_to_move, :undo, %{}))

    assert Batata.Wings.digest(back_to_cube.mesh) == Batata.Wings.digest(original.mesh)
    assert Selection.digest(back_to_cube.selection) == Selection.digest(original.selection)
    assert back_to_cube.geometry_generation == 4

    {redo_move, _result} = Editor.execute!(back_to_cube, command(back_to_cube, :redo, %{}))
    {redo_final, _result} = Editor.execute!(redo_move, command(redo_move, :redo, %{}))

    assert Batata.Wings.digest(redo_final.mesh) == final_mesh_digest
    assert Selection.digest(redo_final.selection) == selection_digest
    assert redo_final.geometry_generation == 6
  end

  test "a branching edit clears redo without recording selection-only changes" do
    original = EditorState.new!(Primitive.cube(), face_ids: [1])

    {moved, _result} =
      Editor.execute!(original, command(original, :move, %{"vector" => [0, 0, 1]}))

    {undone, _result} = Editor.execute!(moved, command(moved, :undo, %{}))

    {selected, _result} =
      Editor.execute!(undone, command(undone, :select, %{"mode" => "add", "face_ids" => [2]}))

    assert length(selected.history.future) == 1
    assert selected.history.past == []

    {branched, _result} =
      Editor.execute!(selected, command(selected, :move, %{"vector" => [0.25, 0, 0]}))

    assert branched.history.future == []
    assert length(branched.history.past) == 1

    error =
      assert_raise Diagnostic, fn -> Editor.execute!(branched, command(branched, :redo, %{})) end

    assert error.code == "E_WINGS_HISTORY_EMPTY"
  end

  test "entry and byte quotas fail closed or evict oldest generations deterministically" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1], max_entries: 2)

    state =
      Enum.reduce(1..3, state, fn _step, current ->
        {next, _result} =
          Editor.execute!(current, command(current, :move, %{"vector" => [0, 0, 0.1]}))

        next
      end)

    assert Enum.map(state.history.past, & &1.source_generation) == [2, 1]
    assert state.history.evicted_generations == [0]

    constrained = EditorState.new!(Primitive.cube(), face_ids: [1], max_bytes: 1)

    error =
      assert_raise Diagnostic, fn ->
        Editor.execute!(constrained, command(constrained, :move, %{"vector" => [0, 0, 1]}))
      end

    assert error.code == "E_WINGS_HISTORY_QUOTA_EXCEEDED"
    assert error.context["before_mesh_digest"] == Batata.Wings.digest(constrained.mesh)
  end

  test "corrupt history cannot replace the current state" do
    original = EditorState.new!(Primitive.cube(), face_ids: [1])

    {moved, _result} =
      Editor.execute!(original, command(original, :move, %{"vector" => [0, 0, 1]}))

    [entry] = moved.history.past
    corrupt = %{entry | digest: String.duplicate("0", 64)}
    state = %{moved | history: %{moved.history | past: [corrupt]}}

    error = assert_raise Diagnostic, fn -> Editor.execute!(state, command(state, :undo, %{})) end
    assert error.code == "E_WINGS_HISTORY_CORRUPT"
    assert Batata.Wings.digest(state.mesh) == Batata.Wings.digest(moved.mesh)
  end

  defp command(state, operation, arguments) do
    EditCommand.new!(
      operation,
      arguments,
      Batata.Wings.digest(state.mesh),
      state.geometry_generation
    )
  end
end
