defmodule Batata.Wings.EditInsetBevelTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.{Diagnostic, EditCommand, Editor, EditorState, Mesh, Primitive, Topology}
  alias Batata.Wings.Topology.Build

  test "inset creates a coplanar cap and closed boundary ring" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1])
    {inset, result} = Editor.execute!(state, command(state, :inset, %{"ratio" => 0.25}))

    assert Topology.stats(Build.build!(inset.mesh)) == %{
             "closed" => true,
             "edges" => 20,
             "euler_characteristic" => 2,
             "faces" => 10,
             "vertices" => 12
           }

    assert inset.mesh.vertices[8] == {-0.75, -0.75, 1.0}
    assert length(result.created.faces) == 4
    assert result.receipt["operation"] == "inset"
  end

  test "segments-one bevel produces a distinct recessed cap" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1])

    {beveled, result} =
      Editor.execute!(state, command(state, :bevel, %{"width" => 0.25, "segments" => 1}))

    stats = Topology.stats(Build.build!(beveled.mesh))
    assert stats["euler_characteristic"] == 2
    assert stats["vertices"] == 12
    assert elem(beveled.mesh.vertices[8], 2) == 0.75
    assert result.receipt["operation"] == "bevel"

    {inset, _result} = Editor.execute!(state, command(state, :inset, %{"distance" => 0.25}))
    refute Batata.Wings.digest(beveled.mesh) == Batata.Wings.digest(inset.mesh)
  end

  test "unsafe ratio reports max_safe_value instead of clamping" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1])

    error =
      assert_raise Diagnostic, fn ->
        Editor.execute!(state, command(state, :inset, %{"ratio" => 0.75}))
      end

    assert error.code == "E_WINGS_EDIT_WOULD_SELF_INTERSECT"
    assert error.context["max_safe_value"] == 0.49
    assert Batata.Wings.digest(state.mesh) == error.context["before_mesh_digest"]
  end

  test "concave faces fail closed before topology mutation" do
    mesh = concave_prism()
    state = EditorState.new!(mesh, face_ids: [1])

    error =
      assert_raise Diagnostic, fn ->
        Editor.execute!(state, command(state, :inset, %{"ratio" => 0.2}))
      end

    assert error.code == "E_WINGS_EDIT_WOULD_SELF_INTERSECT"
    assert Batata.Wings.digest(state.mesh) == Batata.Wings.digest(mesh)
  end

  defp command(state, operation, arguments) do
    EditCommand.new!(
      operation,
      arguments,
      Batata.Wings.digest(state.mesh),
      state.geometry_generation
    )
  end

  defp concave_prism do
    bottom = [{-1, -1, -1}, {1, -1, -1}, {0, 0, -1}, {1, 1, -1}, {-1, 1, -1}]
    top = Enum.map(bottom, fn {x, y, _z} -> {x, y, 1} end)
    vertices = (bottom ++ top) |> Enum.with_index() |> Map.new(fn {point, id} -> {id, point} end)

    Mesh.new!(vertices, %{
      0 => [4, 3, 2, 1, 0],
      1 => [5, 6, 7, 8, 9],
      2 => [0, 1, 6, 5],
      3 => [1, 2, 7, 6],
      4 => [2, 3, 8, 7],
      5 => [3, 4, 9, 8],
      6 => [4, 0, 5, 9]
    })
  end
end
