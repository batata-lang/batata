defmodule Batata.Wings.EditExtrudeTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.{Diagnostic, EditCommand, Editor, EditorState, Primitive, Topology}
  alias Batata.Wings.Topology.Build

  test "single-face region extrusion closes a deterministic solid" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1])

    {extruded, result} =
      Editor.execute!(
        state,
        command(state, %{"mode" => "region", "distance" => 1.0, "direction" => "normal"})
      )

    assert Topology.stats(Build.build!(extruded.mesh)) == %{
             "closed" => true,
             "edges" => 20,
             "euler_characteristic" => 2,
             "faces" => 10,
             "vertices" => 12
           }

    assert extruded.geometry_generation == 1
    assert extruded.selection.face_ids == [1]
    assert length(result.created.vertices) == 4
    assert length(result.created.faces) == 4
    assert Map.fetch!(result.id_remap.faces, 1) == [1]
  end

  test "adjacent faces distinguish region and individual topology" do
    state = EditorState.new!(Primitive.cube(), face_ids: [1, 3])

    {region, _result} =
      Editor.execute!(
        state,
        command(state, %{
          "mode" => "region",
          "distance" => 0.5,
          "direction" => [1.0, 0.0, 1.0]
        })
      )

    {individual, _result} =
      Editor.execute!(
        state,
        command(state, %{"mode" => "individual", "distance" => 0.5, "direction" => "normal"})
      )

    assert Topology.stats(Build.build!(region.mesh)) == %{
             "closed" => true,
             "edges" => 24,
             "euler_characteristic" => 2,
             "faces" => 12,
             "vertices" => 14
           }

    assert Topology.stats(Build.build!(individual.mesh)) == %{
             "closed" => true,
             "edges" => 28,
             "euler_characteristic" => 2,
             "faces" => 14,
             "vertices" => 16
           }

    refute Batata.Wings.digest(region.mesh) == Batata.Wings.digest(individual.mesh)
  end

  test "closed whole-mesh region and quota overflow fail before commit" do
    state = EditorState.new!(Primitive.cube(), face_ids: Enum.to_list(0..5))

    error =
      assert_raise Diagnostic, fn ->
        Editor.execute!(
          state,
          command(state, %{"mode" => "region", "distance" => 1, "direction" => "normal"})
        )
      end

    assert error.code == "E_WINGS_EDIT_PRECONDITION_FAILED"

    one_face = EditorState.new!(Primitive.cube(), face_ids: [1])

    error =
      assert_raise Diagnostic, fn ->
        Editor.execute!(
          one_face,
          command(
            one_face,
            %{"mode" => "individual", "distance" => 1, "direction" => "normal"},
            quota_bytes: 1
          )
        )
      end

    assert error.code == "E_WINGS_EDIT_MEMORY_QUOTA_EXCEEDED"
  end

  test "extrusion is replayable" do
    left = EditorState.new!(Primitive.cube(), face_ids: [1])
    right = EditorState.new!(Primitive.cube(), face_ids: [1])
    arguments = %{"mode" => "region", "distance" => 0.25, "direction" => "normal"}

    {left, left_result} = Editor.execute!(left, command(left, arguments))
    {right, right_result} = Editor.execute!(right, command(right, arguments))

    assert Batata.Wings.digest(left.mesh) == Batata.Wings.digest(right.mesh)
    assert left_result.receipt == right_result.receipt
  end

  defp command(state, arguments, options \\ []) do
    EditCommand.new!(
      :extrude,
      arguments,
      Batata.Wings.digest(state.mesh),
      state.geometry_generation,
      options
    )
  end
end
