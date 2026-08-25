defmodule Batata.Wings.TopologyTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.{Diagnostic, Mesh, Oracle, Primitive, Subdivision, Topology}
  alias Batata.Wings.Topology.Build

  test "cube closes a deterministic winged-edge topology" do
    topology = Primitive.cube() |> Build.build!()

    assert Topology.stats(topology) == %{
             "closed" => true,
             "edges" => 12,
             "euler_characteristic" => 2,
             "faces" => 6,
             "vertices" => 8
           }

    assert Topology.digest(topology) == Topology.digest(topology)
    assert Enum.all?(topology.edges, fn {_id, edge} -> edge.left_face != edge.right_face end)
  end

  test "one Catmull-Clark level produces the closed Wings cube baseline" do
    mesh = Primitive.cube() |> Subdivision.smooth!()
    topology = Build.build!(mesh)

    assert Topology.stats(topology) == %{
             "closed" => true,
             "edges" => 48,
             "euler_characteristic" => 2,
             "faces" => 24,
             "vertices" => 26
           }

    assert mesh.metadata["subdivision_level"] == 1
    assert Enum.all?(mesh.faces, fn {_id, vertices} -> length(vertices) == 4 end)
  end

  test "subdivision is replayable" do
    left = Primitive.cube() |> Subdivision.smooth!(2)
    right = Primitive.cube() |> Subdivision.smooth!(2)

    assert Batata.Wings.digest(left) == Batata.Wings.digest(right)
    assert Topology.stats(Build.build!(left))["euler_characteristic"] == 2
  end

  test "boundary and same-direction face uses fail closed" do
    error =
      assert_raise Diagnostic, fn ->
        Mesh.new!(
          %{0 => {0.0, 0.0, 0.0}, 1 => {1.0, 0.0, 0.0}, 2 => {0.0, 1.0, 0.0}},
          %{0 => [0, 1, 2]}
        )
        |> Build.build!()
      end

    assert error.code == "E_WINGS_NON_MANIFOLD_EDGE"
  end

  test "logical memory pressure rejects before allocating the next mesh" do
    source = Primitive.cube()

    error =
      assert_raise Diagnostic, fn ->
        Subdivision.smooth!(source, 1, quota_bytes: 1)
      end

    assert error.code == "E_WINGS_MEMORY_QUOTA_EXCEEDED"
    assert error.recoverable
    assert error.context["estimated_bytes"] > error.context["quota_bytes"]
    assert Enum.any?(error.actions, &String.contains?(&1["command"], "quota_bytes"))
  end

  @tag :oracle
  test "subdivision matches the pinned upstream Wings3D implementation" do
    report = System.fetch_env!("WINGS_ORACLE_PATH") |> Oracle.compare_cube_smooth!()

    assert report["matches"]
    assert report["counts"] == %{"edges" => 48, "faces" => 24, "vertices" => 26}
    assert report["maximum_position_delta"] <= 1.0e-12
  end
end
