defmodule Batata.Wings.Operation.Inset do
  @moduledoc "Bounded planar face inset and face-boundary bevel construction."

  alias Batata.Wings.{Diagnostic, Geometry, IdentityDelta, Mesh, Vec3}
  alias Batata.Wings.Operation.Delta
  alias Batata.Wings.Topology.Build

  @maximum_ratio 0.49
  @epsilon 1.0e-9

  @spec apply!(Mesh.t(), [Mesh.face_id()], map(), pos_integer()) ::
          {Mesh.t(), IdentityDelta.t(), boolean()}
  def apply!(%Mesh{} = mesh, face_ids, arguments, quota_bytes) do
    {ratio, _maximum} = inset_ratio!(mesh, face_ids, arguments)
    build!(mesh, face_ids, ratio, 0.0, "inset", quota_bytes)
  end

  @spec bevel!(Mesh.t(), [Mesh.face_id()], map(), pos_integer()) ::
          {Mesh.t(), IdentityDelta.t(), boolean()}
  def bevel!(%Mesh{} = mesh, face_ids, arguments, quota_bytes) do
    width = arguments["width"]
    segments = Map.get(arguments, "segments", 1)
    {_centroid, _normal, radius} = region_frame!(mesh, face_ids)

    unless is_number(width) and width > 0 and Geometry.finite_vector?({width, width, width}) and
             segments == 1 do
      precondition!(mesh, face_ids, "bevel requires positive finite width and segments=1")
    end

    maximum = radius * @maximum_ratio

    if width > maximum do
      unsafe!(mesh, face_ids, "bevel width exceeds the convex collapse bound", maximum, width)
    end

    build!(mesh, face_ids, width / radius, -width, "bevel", quota_bytes)
  end

  defp build!(mesh, face_ids, ratio, normal_offset, operation, quota_bytes) do
    reject_empty!(mesh, face_ids, operation)
    topology = Build.build!(mesh)
    selected = MapSet.new(face_ids)
    ensure_connected!(mesh, topology, selected, operation)
    {centroid, normal, _radius} = region_frame!(mesh, face_ids)
    ensure_convex!(mesh, face_ids, normal, operation)
    boundary = boundary_sides(mesh, topology, selected)

    if boundary == [] do
      precondition!(mesh, face_ids, "#{operation} requires a bounded planar face region")
    end

    enforce_quota!(mesh, face_ids, boundary, quota_bytes, operation)
    selected_vertices = selected_vertices(mesh, face_ids)
    first_vertex = next_id(mesh.vertices)
    duplicates = selected_vertices |> Enum.with_index(first_vertex) |> Map.new()

    vertices =
      Enum.reduce(duplicates, mesh.vertices, fn {vertex, duplicate}, positions ->
        point = Map.fetch!(mesh.vertices, vertex)

        inset_point =
          centroid
          |> Vec3.add(Vec3.scale(Vec3.sub(point, centroid), 1.0 - ratio))
          |> Vec3.add(Vec3.scale(normal, normal_offset))

        Map.put(positions, duplicate, inset_point)
      end)

    cap_faces =
      Map.new(mesh.faces, fn {face_id, vertices} ->
        if MapSet.member?(selected, face_id) do
          {face_id, Enum.map(vertices, &Map.fetch!(duplicates, &1))}
        else
          {face_id, vertices}
        end
      end)

    {faces, created_faces} = add_boundary_faces(cap_faces, boundary, duplicates)
    vertices = Delta.retain_used_vertices(vertices, faces)

    candidate =
      Mesh.new!(vertices, faces, Map.put(mesh.metadata, "operation", operation))
      |> Geometry.validate!(operation)

    Build.build!(candidate)

    delta =
      Delta.build!(
        mesh,
        candidate,
        Delta.region_vertex_remap(mesh, duplicates),
        Map.values(duplicates),
        created_faces
      )

    {candidate, delta, true}
  end

  defp inset_ratio!(mesh, face_ids, %{"ratio" => ratio} = arguments) do
    if Map.has_key?(arguments, "distance") do
      precondition!(mesh, face_ids, "inset accepts ratio or distance, not both")
    end

    unless is_number(ratio) and ratio > 0 and Geometry.finite_vector?({ratio, ratio, ratio}) do
      precondition!(mesh, face_ids, "inset ratio must be positive and finite")
    end

    if ratio > @maximum_ratio do
      unsafe!(
        mesh,
        face_ids,
        "inset ratio exceeds the convex collapse bound",
        @maximum_ratio,
        ratio
      )
    end

    {ratio, @maximum_ratio}
  end

  defp inset_ratio!(mesh, face_ids, %{"distance" => distance}) do
    {_centroid, _normal, radius} = region_frame!(mesh, face_ids)
    maximum = radius * @maximum_ratio

    unless is_number(distance) and distance > 0 and
             Geometry.finite_vector?({distance, distance, distance}) do
      precondition!(mesh, face_ids, "inset distance must be positive and finite")
    end

    if distance > maximum do
      unsafe!(
        mesh,
        face_ids,
        "inset distance exceeds the convex collapse bound",
        maximum,
        distance
      )
    end

    {distance / radius, maximum}
  end

  defp inset_ratio!(mesh, face_ids, _arguments) do
    precondition!(mesh, face_ids, "inset requires exactly ratio or distance")
  end

  defp region_frame!(mesh, []) do
    precondition!(mesh, [], "edit requires a non-empty face selection")
  end

  defp region_frame!(mesh, face_ids) do
    normal = Geometry.face_normal!(mesh, hd(face_ids))
    vertices = selected_vertices(mesh, face_ids)
    points = Enum.map(vertices, &Map.fetch!(mesh.vertices, &1))
    centroid = Vec3.average(points)

    planar =
      Enum.all?(face_ids, fn face_id ->
        Vec3.dot(normal, Geometry.face_normal!(mesh, face_id)) > 1.0 - @epsilon
      end) and
        Enum.all?(points, fn point ->
          abs(Vec3.dot(Vec3.sub(point, centroid), normal)) <= @epsilon
        end)

    unless planar do
      precondition!(mesh, face_ids, "inset/bevel requires a consistently oriented planar region")
    end

    radius = points |> Enum.map(&Vec3.length(Vec3.sub(&1, centroid))) |> Enum.min()

    if radius <= @epsilon do
      unsafe!(mesh, face_ids, "selected region has no safe inset radius", 0.0, 0.0)
    end

    {centroid, normal, radius}
  end

  defp ensure_connected!(mesh, topology, selected, operation) do
    first = selected |> Enum.min()
    reached = visit_faces([first], selected, topology, MapSet.new())

    unless MapSet.equal?(reached, selected) do
      precondition!(
        mesh,
        MapSet.to_list(selected),
        "#{operation} requires one connected face region"
      )
    end
  end

  defp visit_faces([], _selected, _topology, reached), do: reached

  defp visit_faces([face | pending], selected, topology, reached) do
    if MapSet.member?(reached, face) do
      visit_faces(pending, selected, topology, reached)
    else
      neighbors =
        topology.face_edges
        |> Map.fetch!(face)
        |> Enum.flat_map(fn edge_id ->
          edge = Map.fetch!(topology.edges, edge_id)
          [edge.left_face, edge.right_face]
        end)
        |> Enum.filter(&MapSet.member?(selected, &1))

      visit_faces(neighbors ++ pending, selected, topology, MapSet.put(reached, face))
    end
  end

  defp ensure_convex!(mesh, face_ids, normal, operation) do
    convex = Enum.all?(face_ids, &convex_face?(mesh, &1, normal))

    unless convex do
      unsafe!(
        mesh,
        face_ids,
        "#{operation} does not admit a concave face region",
        @maximum_ratio,
        0.0
      )
    end
  end

  defp convex_face?(mesh, face_id, normal) do
    points = mesh.faces |> Map.fetch!(face_id) |> Enum.map(&Map.fetch!(mesh.vertices, &1))
    triples = Enum.zip([points, rotate(points, 1), rotate(points, 2)])

    Enum.all?(triples, fn {left, middle, right} ->
      middle |> Vec3.sub(left) |> Vec3.cross(Vec3.sub(right, middle)) |> Vec3.dot(normal) >=
        -@epsilon
    end)
  end

  defp boundary_sides(mesh, topology, selected) do
    mesh.faces
    |> Enum.filter(fn {face_id, _vertices} -> MapSet.member?(selected, face_id) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {face_id, vertices} ->
      vertices
      |> cyclic_pairs()
      |> Enum.filter(fn {from, to} -> boundary_edge?(topology, selected, from, to) end)
      |> Enum.map(fn {from, to} -> {face_id, from, to} end)
    end)
  end

  defp boundary_edge?(topology, selected, from, to) do
    edge =
      Enum.find_value(topology.edges, fn {_id, edge} ->
        if MapSet.new([edge.start, edge.end]) == MapSet.new([from, to]), do: edge
      end)

    not (MapSet.member?(selected, edge.left_face) and MapSet.member?(selected, edge.right_face))
  end

  defp add_boundary_faces(faces, boundary, duplicates) do
    first_face = next_id(faces)

    additions =
      boundary
      |> Enum.with_index(first_face)
      |> Enum.map(fn {{_face, from, to}, face_id} ->
        {face_id, [from, to, Map.fetch!(duplicates, to), Map.fetch!(duplicates, from)]}
      end)

    {Map.merge(faces, Map.new(additions)), Enum.map(additions, &elem(&1, 0))}
  end

  defp enforce_quota!(mesh, face_ids, boundary, quota_bytes, operation) do
    growth = length(selected_vertices(mesh, face_ids)) * 32 + length(boundary) * 112
    estimate = Geometry.estimate_bytes(mesh) + growth

    if estimate > quota_bytes do
      raise Diagnostic.new!(
              "E_WINGS_EDIT_MEMORY_QUOTA_EXCEEDED",
              "#{operation} candidate exceeds its declared logical memory quota",
              %{
                "before_mesh_digest" => Batata.Wings.digest(mesh),
                "estimated_bytes" => estimate,
                "operation" => operation,
                "quota_bytes" => quota_bytes
              },
              [%{"command" => "increase quota_bytes to at least #{estimate}"}],
              true
            )
    end
  end

  defp unsafe!(mesh, face_ids, message, maximum, observed) do
    raise Diagnostic.new!(
            "E_WINGS_EDIT_WOULD_SELF_INTERSECT",
            message,
            %{
              "before_mesh_digest" => Batata.Wings.digest(mesh),
              "max_safe_value" => maximum,
              "observed_value" => observed,
              "selection" => face_ids
            },
            [%{"command" => "retry with a value no greater than #{maximum}"}],
            true
          )
  end

  defp precondition!(mesh, face_ids, message) do
    raise Diagnostic.new!(
            "E_WINGS_EDIT_PRECONDITION_FAILED",
            message,
            %{
              "before_mesh_digest" => Batata.Wings.digest(mesh),
              "selection" => face_ids
            },
            [%{"command" => "select one connected convex planar face region"}],
            true
          )
  end

  defp selected_vertices(mesh, face_ids) do
    face_ids |> Enum.flat_map(&Map.fetch!(mesh.faces, &1)) |> Enum.uniq() |> Enum.sort()
  end

  defp cyclic_pairs([first | rest] = values), do: Enum.zip(values, rest ++ [first])
  defp rotate(values, count), do: Enum.drop(values, count) ++ Enum.take(values, count)
  defp next_id(map), do: map |> Map.keys() |> Enum.max(fn -> -1 end) |> Kernel.+(1)

  defp reject_empty!(mesh, [], operation),
    do: precondition!(mesh, [], "#{operation} requires a face selection")

  defp reject_empty!(_mesh, _face_ids, _operation), do: :ok
end
