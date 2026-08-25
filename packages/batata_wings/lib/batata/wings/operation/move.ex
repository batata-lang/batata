defmodule Batata.Wings.Operation.Move do
  @moduledoc "Deterministic face translation derived from `wings_move`."

  alias Batata.Wings.{Diagnostic, Geometry, IdentityDelta, Mesh, Vec3}
  alias Batata.Wings.Topology.Build

  @spec apply!(Mesh.t(), [Mesh.face_id()], map(), pos_integer()) ::
          {Mesh.t(), IdentityDelta.t(), boolean()}
  def apply!(%Mesh{} = mesh, face_ids, arguments, quota_bytes) do
    reject_empty!(mesh, face_ids)
    displacement = displacement!(mesh, face_ids, arguments)

    if no_op?(displacement) do
      topology = Build.build!(mesh)
      {mesh, IdentityDelta.identity(mesh, Map.keys(topology.edges)), false}
    else
      enforce_quota!(mesh, quota_bytes)
      vertices = move_vertices(mesh, face_ids, displacement)

      candidate =
        Mesh.new!(vertices, mesh.faces, Map.put(mesh.metadata, "operation", "move_faces"))
        |> Geometry.validate!("move")

      topology = Build.build!(candidate)
      {candidate, IdentityDelta.identity(mesh, Map.keys(topology.edges)), true}
    end
  end

  defp displacement!(mesh, face_ids, %{"vector" => [x, y, z]}) do
    vector = {x, y, z}

    unless Geometry.finite_vector?(vector) do
      precondition!(mesh, face_ids, "move vector must contain three finite numbers")
    end

    {:vector, vector}
  end

  defp displacement!(mesh, face_ids, %{"normal_distance" => distance}) do
    unless is_number(distance) and Geometry.finite_vector?({distance, distance, distance}) do
      precondition!(mesh, face_ids, "normal distance must be finite")
    end

    {:normal, distance}
  end

  defp displacement!(mesh, face_ids, _arguments) do
    precondition!(mesh, face_ids, "move requires exactly vector or normal_distance")
  end

  defp move_vertices(mesh, face_ids, {:vector, vector}) do
    selected_vertices(mesh, face_ids)
    |> Enum.reduce(mesh.vertices, fn vertex, positions ->
      Map.update!(positions, vertex, &Vec3.add(&1, vector))
    end)
  end

  defp move_vertices(mesh, face_ids, {:normal, distance}) do
    normals = Map.new(face_ids, &{&1, Geometry.face_normal!(mesh, &1)})

    selected_vertices(mesh, face_ids)
    |> Enum.reduce(mesh.vertices, fn vertex, positions ->
      normal =
        face_ids
        |> Enum.filter(&(vertex in Map.fetch!(mesh.faces, &1)))
        |> Enum.map(&Map.fetch!(normals, &1))
        |> Vec3.average()
        |> Vec3.normalize()

      Map.update!(positions, vertex, &Vec3.add(&1, Vec3.scale(normal, distance)))
    end)
  end

  defp selected_vertices(mesh, face_ids) do
    face_ids
    |> Enum.flat_map(&Map.fetch!(mesh.faces, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp no_op?({:vector, vector}), do: Vec3.length(vector) == 0.0
  defp no_op?({:normal, distance}), do: distance == 0

  defp reject_empty!(mesh, []) do
    precondition!(mesh, [], "move requires a non-empty face selection")
  end

  defp reject_empty!(_mesh, _face_ids), do: :ok

  defp enforce_quota!(mesh, quota_bytes) do
    estimate = Geometry.estimate_bytes(mesh)

    if estimate > quota_bytes do
      raise Diagnostic.new!(
              "E_WINGS_EDIT_MEMORY_QUOTA_EXCEEDED",
              "move candidate exceeds its declared logical memory quota",
              %{
                "before_mesh_digest" => Batata.Wings.digest(mesh),
                "estimated_bytes" => estimate,
                "operation" => "move",
                "quota_bytes" => quota_bytes
              },
              [%{"command" => "increase quota_bytes to at least #{estimate}"}],
              true
            )
    end
  end

  defp precondition!(mesh, face_ids, message) do
    raise Diagnostic.new!(
            "E_WINGS_EDIT_PRECONDITION_FAILED",
            message,
            %{
              "before_mesh_digest" => Batata.Wings.digest(mesh),
              "operation" => "move",
              "selection" => face_ids
            },
            [%{"command" => "select faces and provide a closed move argument"}],
            true
          )
  end
end
