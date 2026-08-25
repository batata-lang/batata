defmodule Batata.Wings.Operation.Extrude do
  @moduledoc "Closed individual and region face extrusion derived from Wings3D."

  alias Batata.Wings.{Diagnostic, Geometry, IdentityDelta, Mesh, Vec3}
  alias Batata.Wings.Operation.Delta
  alias Batata.Wings.Topology.Build

  @spec apply!(Mesh.t(), [Mesh.face_id()], map(), pos_integer()) ::
          {Mesh.t(), IdentityDelta.t(), boolean()}
  def apply!(%Mesh{} = mesh, face_ids, arguments, quota_bytes) do
    reject_empty!(mesh, face_ids)
    {mode, distance, direction} = arguments!(mesh, face_ids, arguments)

    enforce_quota!(mesh, face_ids, mode, quota_bytes)
    source_topology = Build.build!(mesh)

    {vertices, faces, vertex_remap, created_vertices, created_faces} =
      case mode do
        :region -> extrude_region(mesh, source_topology, face_ids, distance, direction)
        :individual -> extrude_individual(mesh, face_ids, distance, direction)
      end

    vertices = Delta.retain_used_vertices(vertices, faces)

    candidate =
      Mesh.new!(vertices, faces, Map.put(mesh.metadata, "operation", "extrude_#{mode}"))
      |> Geometry.validate!("extrude")

    Build.build!(candidate)

    delta = Delta.build!(mesh, candidate, vertex_remap, created_vertices, created_faces)

    {candidate, delta, true}
  end

  defp extrude_region(mesh, topology, face_ids, distance, direction) do
    selected = MapSet.new(face_ids)
    boundary = boundary_sides(mesh, topology, selected)

    if boundary == [] do
      precondition!(mesh, face_ids, "region extrusion requires a boundary")
    end

    selected_vertices = selected_vertices(mesh, face_ids)
    first_vertex = next_id(mesh.vertices)
    duplicates = selected_vertices |> Enum.with_index(first_vertex) |> Map.new()
    vertex_remap = Delta.region_vertex_remap(mesh, duplicates)
    vertices = add_region_vertices(mesh, face_ids, duplicates, distance, direction)

    cap_faces =
      Map.new(mesh.faces, fn {face_id, vertices} ->
        if MapSet.member?(selected, face_id) do
          {face_id, Enum.map(vertices, &Map.fetch!(duplicates, &1))}
        else
          {face_id, vertices}
        end
      end)

    {faces, created_faces} = add_region_sides(cap_faces, boundary, duplicates)
    {vertices, faces, vertex_remap, Map.values(duplicates), created_faces}
  end

  defp extrude_individual(mesh, face_ids, distance, direction) do
    first_vertex = next_id(mesh.vertices)

    {duplicates, _next_vertex} =
      Enum.reduce(face_ids, {%{}, first_vertex}, fn face_id, {allocated, cursor} ->
        ids = Map.fetch!(mesh.faces, face_id)

        additions =
          ids
          |> Enum.with_index(cursor)
          |> Map.new(fn {vertex, id} -> {{face_id, vertex}, id} end)

        {Map.merge(allocated, additions), cursor + length(ids)}
      end)

    vertices =
      Enum.reduce(duplicates, mesh.vertices, fn {{face_id, vertex}, new_id}, positions ->
        normal = displacement(mesh, [face_id], vertex, distance, direction)
        Map.put(positions, new_id, Vec3.add(Map.fetch!(mesh.vertices, vertex), normal))
      end)

    cap_faces =
      Map.new(mesh.faces, fn {face_id, vertices} ->
        if face_id in face_ids do
          {face_id, Enum.map(vertices, &Map.fetch!(duplicates, {face_id, &1}))}
        else
          {face_id, vertices}
        end
      end)

    {faces, created_faces} = add_individual_sides(cap_faces, mesh, face_ids, duplicates)

    vertex_remap =
      Map.new(mesh.vertices, fn {vertex, _position} ->
        targets = duplicates_for_vertex(duplicates, face_ids, vertex)
        {vertex, [vertex | targets]}
      end)

    {vertices, faces, vertex_remap, Map.values(duplicates), created_faces}
  end

  defp add_region_vertices(mesh, face_ids, duplicates, distance, direction) do
    Enum.reduce(duplicates, mesh.vertices, fn {vertex, new_id}, positions ->
      vector = displacement(mesh, face_ids, vertex, distance, direction)
      Map.put(positions, new_id, Vec3.add(Map.fetch!(mesh.vertices, vertex), vector))
    end)
  end

  defp add_region_sides(faces, boundary, duplicates) do
    first_face = next_id(faces)

    additions =
      boundary
      |> Enum.with_index(first_face)
      |> Enum.map(fn {{_face, from, to}, face_id} ->
        {face_id, [from, to, Map.fetch!(duplicates, to), Map.fetch!(duplicates, from)]}
      end)

    {Map.merge(faces, Map.new(additions)), Enum.map(additions, &elem(&1, 0))}
  end

  defp add_individual_sides(faces, mesh, face_ids, duplicates) do
    first_face = next_id(faces)

    additions =
      face_ids
      |> Enum.flat_map(fn face_id ->
        mesh.faces
        |> Map.fetch!(face_id)
        |> cyclic_pairs()
        |> Enum.map(&{face_id, &1})
      end)
      |> Enum.with_index(first_face)
      |> Enum.map(fn {{face_id, {from, to}}, side_id} ->
        {side_id,
         [
           from,
           to,
           Map.fetch!(duplicates, {face_id, to}),
           Map.fetch!(duplicates, {face_id, from})
         ]}
      end)

    {Map.merge(faces, Map.new(additions)), Enum.map(additions, &elem(&1, 0))}
  end

  defp boundary_sides(mesh, topology, selected) do
    mesh.faces
    |> Enum.filter(fn {face_id, _vertices} -> MapSet.member?(selected, face_id) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {face_id, vertices} ->
      Enum.filter(cyclic_pairs(vertices), fn {from, to} ->
        edge = edge_for!(topology, from, to)

        not (MapSet.member?(selected, edge.left_face) and
               MapSet.member?(selected, edge.right_face))
      end)
      |> Enum.map(fn {from, to} -> {face_id, from, to} end)
    end)
  end

  defp edge_for!(topology, from, to) do
    Enum.find_value(topology.edges, fn {_id, edge} ->
      if MapSet.new([edge.start, edge.end]) == MapSet.new([from, to]), do: edge
    end)
  end

  defp displacement(_mesh, _face_ids, _vertex, distance, {:vector, vector}) do
    Vec3.scale(Vec3.normalize(vector), distance)
  end

  defp displacement(mesh, face_ids, vertex, distance, :normal) do
    face_ids
    |> Enum.filter(&(vertex in Map.fetch!(mesh.faces, &1)))
    |> Enum.map(&Geometry.face_normal!(mesh, &1))
    |> Vec3.average()
    |> Vec3.normalize()
    |> Vec3.scale(distance)
  end

  defp arguments!(mesh, face_ids, arguments) do
    mode = parse_mode(arguments["mode"])
    distance = arguments["distance"]
    direction = parse_direction(arguments["direction"])

    unless mode != nil and is_number(distance) and distance > 0 and
             Geometry.finite_vector?({distance, distance, distance}) and direction != nil do
      precondition!(
        mesh,
        face_ids,
        "extrude requires mode, positive finite distance, and normal or vector direction"
      )
    end

    {mode, distance, direction}
  end

  defp parse_mode("region"), do: :region
  defp parse_mode("individual"), do: :individual
  defp parse_mode(_mode), do: nil

  defp parse_direction("normal"), do: :normal

  defp parse_direction([x, y, z]) do
    vector = {x, y, z}
    if Geometry.finite_vector?(vector) and Vec3.length(vector) > 0, do: {:vector, vector}
  end

  defp parse_direction(_direction), do: nil

  defp enforce_quota!(mesh, face_ids, mode, quota_bytes) do
    selected_corners =
      face_ids |> Enum.map(&Map.fetch!(mesh.faces, &1)) |> Enum.map(&length/1) |> Enum.sum()

    selected_vertices = length(selected_vertices(mesh, face_ids))
    vertex_growth = if mode == :individual, do: selected_corners, else: selected_vertices
    face_growth = selected_corners
    estimate = Geometry.estimate_bytes(mesh) + vertex_growth * 32 + face_growth * 112

    if estimate > quota_bytes do
      raise Diagnostic.new!(
              "E_WINGS_EDIT_MEMORY_QUOTA_EXCEEDED",
              "extrusion candidate exceeds its declared logical memory quota",
              %{
                "before_mesh_digest" => Batata.Wings.digest(mesh),
                "estimated_bytes" => estimate,
                "operation" => "extrude",
                "quota_bytes" => quota_bytes
              },
              [%{"command" => "increase quota_bytes to at least #{estimate}"}],
              true
            )
    end
  end

  defp duplicates_for_vertex(duplicates, face_ids, vertex) do
    Enum.flat_map(face_ids, fn face_id ->
      case Map.fetch(duplicates, {face_id, vertex}) do
        {:ok, duplicate} -> [duplicate]
        :error -> []
      end
    end)
  end

  defp selected_vertices(mesh, face_ids) do
    face_ids |> Enum.flat_map(&Map.fetch!(mesh.faces, &1)) |> Enum.uniq() |> Enum.sort()
  end

  defp cyclic_pairs([first | rest] = values), do: Enum.zip(values, rest ++ [first])

  defp next_id(map), do: map |> Map.keys() |> Enum.max(fn -> -1 end) |> Kernel.+(1)

  defp reject_empty!(mesh, []), do: precondition!(mesh, [], "extrude requires a face selection")
  defp reject_empty!(_mesh, _face_ids), do: :ok

  defp precondition!(mesh, face_ids, message) do
    raise Diagnostic.new!(
            "E_WINGS_EDIT_PRECONDITION_FAILED",
            message,
            %{
              "before_mesh_digest" => Batata.Wings.digest(mesh),
              "operation" => "extrude",
              "selection" => face_ids
            },
            [
              %{
                "command" => "select a bounded face region and provide closed extrusion arguments"
              }
            ],
            true
          )
  end
end
