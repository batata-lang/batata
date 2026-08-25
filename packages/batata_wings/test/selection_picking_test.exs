defmodule Batata.Wings.SelectionPickingTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.{Diagnostic, Picking, Primitive, Selection}

  test "face selection operations are canonical and revisioned independently" do
    mesh = Primitive.cube()
    selection = Selection.new!(mesh)

    selection = Selection.update!(selection, mesh, 0, :replace, [5, 1, 5])
    assert selection.face_ids == [1, 5]
    assert selection.revision == 1

    unchanged = Selection.update!(selection, mesh, 0, :add, [1])
    assert unchanged == selection

    selection = Selection.update!(selection, mesh, 0, :toggle, [0, 5])
    assert selection.face_ids == [0, 1]
    assert selection.revision == 2

    selection = Selection.update!(selection, mesh, 0, :remove, [0])
    selection = Selection.update!(selection, mesh, 0, :clear)
    assert selection.face_ids == []
    assert selection.revision == 4
  end

  test "ray picking returns canonical face identity with deterministic triangle ties" do
    mesh = Primitive.cube()

    assert {:hit, hit} = Picking.pick_face(mesh, {0.0, 0.0, 5.0}, {0.0, 0.0, -1.0})
    assert hit.face_id == 1
    assert hit.triangle_ordinal == 0
    assert_in_delta hit.distance, 4.0, 1.0e-12
    assert hit.position == {0.0, 0.0, 1.0}

    assert {:hit, edge_hit} =
             Picking.pick_face(mesh, {0.0, 0.0, 5.0}, {0.0, 0.0, -1.0}, epsilon: 1.0e-8)

    assert edge_hit.triangle_ordinal == 0
  end

  test "front-face policy and malformed rays fail closed" do
    mesh = Primitive.cube()

    assert :miss ==
             Picking.pick_face(mesh, {0.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, backfaces: :front)

    error =
      assert_raise Diagnostic, fn ->
        Picking.pick_face(mesh, {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0})
      end

    assert error.code == "E_WINGS_EDIT_PRECONDITION_FAILED"
  end
end
