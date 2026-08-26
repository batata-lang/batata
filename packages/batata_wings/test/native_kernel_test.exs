defmodule Batata.Wings.Native.KernelTest do
  use ExUnit.Case, async: false

  alias Batata.Wings.Native.{Build, Kernel, Source}
  alias Beaver.MLIR.Context

  test "shared kernel closes cube topology and moves one selected face on BEAM" do
    state = Kernel.cube_state()
    assert Kernel.topology_stats(state) == {true, 8, 12, 6, 2}

    {selected, 0} = Kernel.select_face(state, 1, 0)
    {moved, 0} = Kernel.move_selected(selected, 0, 0, 250, 0, 1_024)

    assert Kernel.generation(moved) == 1
    assert Kernel.vertex_position(moved, 4) == {4, -1_000, -1_000, 1_250}
    assert Kernel.vertex_position(moved, 0) == {0, -1_000, -1_000, -1_000}
    assert Kernel.topology_stats(moved) == {true, 8, 12, 6, 2}
  end

  test "native move fails closed on stale generation, invalid selection, and quota" do
    state = Kernel.cube_state()
    assert {^state, 1} = Kernel.select_face(state, 1, 7)
    assert {^state, 2} = Kernel.select_face(state, 99, 0)

    {selected, 0} = Kernel.select_face(state, 1, 0)
    assert {^selected, 1} = Kernel.move_selected(selected, 0, 0, 1, 7, 1_024)
    assert {^selected, 3} = Kernel.move_selected(selected, 0, 0, 1, 0, 1)
    assert {^selected, 0} = Kernel.move_selected(selected, 0, 0, 0, 0, 1_024)
  end

  test "fixed-point ray picking and editor move evolve one closed state" do
    {selected, 0} = Kernel.editor_pointer_button(nil, 3, 0, 0, 5_000, 0, 0, -10)
    assert Kernel.selection(selected) == [1]
    assert elem(Kernel.selected_triangle_indices(selected), 1) == [4, 5, 6, 4, 6, 7]

    {moved, 1} = Kernel.editor_move(selected, 0, 0, 250, 0, 1_024)
    assert Kernel.generation(moved) == 1
    assert Kernel.vertex_position(moved, 4) == {4, -1_000, -1_000, 1_250}
    assert Kernel.state_code(moved) == 1_101_000

    assert {^moved, -1} = Kernel.editor_move(moved, 0, 0, 250, 0, 1_024)
    assert {^moved, 1} = Kernel.editor_pointer_button(moved, 3, 0, 0, 5_000, 0, 0, -10)

    {undone, 2} = Kernel.editor_undo(moved, 1)
    assert Kernel.vertex_position(undone, 4) == {4, -1_000, -1_000, 1_000}

    {redone, 3} = Kernel.editor_redo(undone, 2)
    assert Kernel.vertex_position(redone, 4) == {4, -1_000, -1_000, 1_250}
    assert {^redone, -1} = Kernel.editor_undo(redone, 2)
  end

  test "native move rejects an out-of-range fixed-point candidate without mutation" do
    {selected, 0} = Kernel.select_face(Kernel.cube_state(), 1, 0)

    assert {^selected, 4} =
             Kernel.move_selected(selected, 0, 0, 1_000_000, 0, 1_024)
  end

  test "the checked-in kernel source executes through Batata native lowering" do
    ctx = Context.create()
    on_exit(fn -> Context.destroy(ctx) end)

    assert Batata.execute(Source.read!(), ctx) == {100_000}
    assert Source.identity()["source_sha256"] |> byte_size() == 64
  end

  @tag :tmp_dir
  test "AOT receipt proves topology and move symbols come from the checked-in kernel", %{
    tmp_dir: tmp_dir
  } do
    ctx = Context.create()
    on_exit(fn -> Context.destroy(ctx) end)

    output = Build.build!(tmp_dir, ctx)
    receipt = output.receipt |> File.read!() |> JSON.decode!()

    assert receipt["source"] == Source.identity()
    assert receipt["artifact_sha256"] |> byte_size() == 64

    assert Enum.any?(receipt["functions"], fn function ->
             function["name"] == "move_selected" and function["arity"] == 6
           end)

    assert Enum.any?(receipt["functions"], fn function ->
             function["name"] == "editor_redo" and function["arity"] == 2
           end)

    assert File.regular?(output.object)
    assert File.regular?(output.archive)
  end
end
