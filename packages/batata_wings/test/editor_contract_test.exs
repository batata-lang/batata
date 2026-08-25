defmodule Batata.Wings.EditorContractTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.{
    CanonicalJSON,
    Diagnostic,
    EditCommand,
    EditorState,
    EditResult,
    IdentityDelta,
    Primitive,
    Selection,
    Topology
  }

  alias Batata.Wings.Topology.Build

  test "editor state and commands have deterministic canonical identities" do
    mesh = Primitive.cube()
    left = EditorState.new!(mesh, face_ids: [5, 1, 5], max_entries: 8, max_bytes: 4096)
    right = EditorState.new!(mesh, face_ids: [1, 5], max_entries: 8, max_bytes: 4096)

    assert left.selection.face_ids == [1, 5]
    assert EditorState.digest(left) == EditorState.digest(right)

    command =
      EditCommand.new!(
        :move,
        %{"face_ids" => [1, 5], "vector" => [0.0, 0.0, 1.0]},
        Batata.Wings.digest(mesh),
        0,
        quota_bytes: 4096
      )

    assert EditCommand.digest(command) == EditCommand.digest(command)

    assert JSON.decode!(CanonicalJSON.encode!(EditCommand.canonical_map(command)))["operation"] ==
             "move"
  end

  test "selection is bound to canonical face identity and mesh generation" do
    mesh = Primitive.cube()
    selection = Selection.new!(mesh, [1], 2)

    assert Selection.validate!(selection, mesh, 2) == selection

    error =
      assert_raise Diagnostic, fn ->
        Selection.validate!(selection, mesh, 3)
      end

    assert error.code == "E_WINGS_SELECTION_STALE"

    invalid =
      assert_raise Diagnostic, fn ->
        Selection.new!(mesh, [999], 0)
      end

    assert invalid.code == "E_WINGS_SELECTION_INVALID"
  end

  test "identity results expose explicit created and deleted sets" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1])
    topology = Build.build!(state.mesh)
    delta = IdentityDelta.identity(state.mesh, Map.keys(topology.edges))

    result =
      EditResult.new!(
        state,
        delta,
        %{
          "after_state_digest" => EditorState.digest(state),
          "before_state_digest" => EditorState.digest(state),
          "operation" => "select"
        },
        false
      )

    canonical = EditResult.canonical_map(result)

    assert canonical["changed"] == false
    assert canonical["created"] == %{"edges" => [], "faces" => [], "vertices" => []}
    assert map_size(result.id_remap.edges) == Topology.stats(topology)["edges"]
  end

  test "malformed edit commands fail closed" do
    error =
      assert_raise Diagnostic, fn ->
        EditCommand.new!(:move, %{}, Batata.Wings.digest(Primitive.cube()), 0, quota_bytes: 0)
      end

    assert error.code == "E_WINGS_EDIT_PRECONDITION_FAILED"
  end
end
