defmodule Batata.Wings.Subdivision do
  @moduledoc "Closed Catmull-Clark subdivision derived from `wings_subdiv`."

  alias Batata.Wings.{Diagnostic, Mesh, Topology, Vec3}
  alias Batata.Wings.Topology.Build

  @default_quota_bytes 64 * 1024 * 1024

  @spec smooth!(Mesh.t(), non_neg_integer(), keyword()) :: Mesh.t()
  def smooth!(%Mesh{} = mesh, levels \\ 1, options \\ [])
      when is_integer(levels) and levels >= 0 do
    quota = Keyword.get(options, :quota_bytes, @default_quota_bytes)

    Enum.reduce(1..levels//1, mesh, fn level, current ->
      topology = Build.build!(current)
      enforce_quota!(topology, quota, level)
      smooth_once(topology, level)
    end)
  end

  @spec estimate_next_bytes(Topology.t()) :: non_neg_integer()
  def estimate_next_bytes(%Topology{} = topology) do
    new_vertices =
      map_size(topology.mesh.vertices) + map_size(topology.edges) + map_size(topology.mesh.faces)

    new_faces = topology.mesh.faces |> Map.values() |> Enum.map(&Kernel.length/1) |> Enum.sum()
    new_vertices * 32 + new_faces * 80
  end

  defp smooth_once(%Topology{} = topology, level) do
    mesh = topology.mesh

    face_points =
      Map.new(mesh.faces, fn {face, vertices} -> {face, average_vertices(mesh, vertices)} end)

    edge_points =
      Map.new(topology.edges, fn {edge_id, edge} ->
        point =
          Vec3.average([
            Map.fetch!(mesh.vertices, edge.start),
            Map.fetch!(mesh.vertices, edge.end),
            Map.fetch!(face_points, edge.left_face),
            Map.fetch!(face_points, edge.right_face)
          ])

        {edge_id, point}
      end)

    moved_vertices =
      Map.new(mesh.vertices, fn {vertex, point} ->
        {vertex, move_vertex(vertex, point, topology, face_points)}
      end)

    next_id = mesh.vertices |> Map.keys() |> Enum.max(fn -> -1 end) |> Kernel.+(1)
    edge_vertex_ids = topology.edges |> Map.keys() |> Enum.sort() |> allocate_ids(next_id)
    face_start = next_id + map_size(edge_vertex_ids)
    face_vertex_ids = mesh.faces |> Map.keys() |> Enum.sort() |> allocate_ids(face_start)

    vertices =
      moved_vertices
      |> Map.merge(remap_points(edge_points, edge_vertex_ids))
      |> Map.merge(remap_points(face_points, face_vertex_ids))

    faces = subdivided_faces(mesh, topology, edge_vertex_ids, face_vertex_ids)

    Mesh.new!(
      vertices,
      faces,
      mesh.metadata
      |> Map.put("operation", "catmull_clark")
      |> Map.put("subdivision_level", level)
    )
  end

  defp move_vertex(vertex, point, topology, face_points) do
    edge_ids = Map.fetch!(topology.vertex_edges, vertex)
    edges = Enum.map(edge_ids, &Map.fetch!(topology.edges, &1))
    face_ids = edges |> Enum.flat_map(&[&1.left_face, &1.right_face]) |> Enum.uniq()
    count = Kernel.length(face_ids)
    faces_average = face_ids |> Enum.map(&Map.fetch!(face_points, &1)) |> Vec3.average()

    edge_midpoint_average =
      edges
      |> Enum.map(fn edge ->
        Vec3.average([
          Map.fetch!(topology.mesh.vertices, edge.start),
          Map.fetch!(topology.mesh.vertices, edge.end)
        ])
      end)
      |> Vec3.average()

    faces_average
    |> Vec3.add(Vec3.scale(edge_midpoint_average, 2))
    |> Vec3.add(Vec3.scale(point, count - 3))
    |> Vec3.scale(1 / count)
  end

  defp subdivided_faces(mesh, topology, edge_vertex_ids, face_vertex_ids) do
    mesh.faces
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {face, vertices} ->
      edges = Map.fetch!(topology.face_edges, face)
      previous_edges = [List.last(edges) | Enum.drop(edges, -1)]

      Enum.zip([vertices, edges, previous_edges])
      |> Enum.map(fn {vertex, following_edge, previous_edge} ->
        [
          vertex,
          Map.fetch!(edge_vertex_ids, following_edge),
          Map.fetch!(face_vertex_ids, face),
          Map.fetch!(edge_vertex_ids, previous_edge)
        ]
      end)
    end)
    |> Enum.with_index()
    |> Map.new(fn {vertices, face} -> {face, vertices} end)
  end

  defp average_vertices(mesh, vertices) do
    vertices |> Enum.map(&Map.fetch!(mesh.vertices, &1)) |> Vec3.average()
  end

  defp allocate_ids(keys, first_id) do
    keys |> Enum.with_index(first_id) |> Map.new()
  end

  defp remap_points(points, ids) do
    Map.new(points, fn {source_id, point} -> {Map.fetch!(ids, source_id), point} end)
  end

  defp enforce_quota!(topology, quota, level) do
    estimate = estimate_next_bytes(topology)

    if not (is_integer(quota) and quota > 0) or estimate > quota do
      raise Diagnostic.new!(
              "E_WINGS_MEMORY_QUOTA_EXCEEDED",
              "subdivision output exceeds its declared logical memory quota",
              %{
                "estimated_bytes" => estimate,
                "level" => level,
                "mesh_digest" => Batata.Wings.digest(topology.mesh),
                "quota_bytes" => quota
              },
              [
                %{"command" => "reduce subdivision levels"},
                %{"command" => "increase quota_bytes to at least #{estimate}"}
              ],
              true
            )
    end
  end
end
