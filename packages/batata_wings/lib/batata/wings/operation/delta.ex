defmodule Batata.Wings.Operation.Delta do
  @moduledoc false

  alias Batata.Wings.{IdentityDelta, Mesh, Topology}
  alias Batata.Wings.Topology.Build

  @spec build!(Mesh.t(), Mesh.t(), map(), [non_neg_integer()], [non_neg_integer()]) ::
          IdentityDelta.t()
  def build!(
        %Mesh{} = source_mesh,
        %Mesh{} = target_mesh,
        vertex_remap,
        created_vertices,
        created_faces
      ) do
    source = Build.build!(source_mesh)
    target = Build.build!(target_mesh)
    retained_vertices = target_mesh.vertices |> Map.keys() |> MapSet.new()

    vertices =
      Map.new(vertex_remap, fn {source_id, targets} ->
        {source_id, Enum.filter(targets, &MapSet.member?(retained_vertices, &1))}
      end)

    edges = edge_remap(source, target, vertices)
    faces = Map.new(source_mesh.faces, fn {face_id, _vertices} -> {face_id, [face_id]} end)
    mapped_edges = edges |> Map.values() |> List.flatten() |> MapSet.new()

    created_edges = target.edges |> Map.keys() |> Enum.reject(&MapSet.member?(mapped_edges, &1))
    deleted_edges = edges |> Enum.filter(&(elem(&1, 1) == [])) |> Enum.map(&elem(&1, 0))
    deleted_vertices = Map.keys(source_mesh.vertices) -- Map.keys(target_mesh.vertices)

    IdentityDelta.new!(
      vertices,
      edges,
      faces,
      %{vertices: created_vertices, edges: created_edges, faces: created_faces},
      %{vertices: deleted_vertices, edges: deleted_edges, faces: []}
    )
  end

  @spec region_vertex_remap(Mesh.t(), map()) :: map()
  def region_vertex_remap(%Mesh{} = mesh, duplicates) do
    Map.new(mesh.vertices, fn {vertex, _position} ->
      targets =
        case Map.fetch(duplicates, vertex) do
          {:ok, duplicate} -> [vertex, duplicate]
          :error -> [vertex]
        end

      {vertex, targets}
    end)
  end

  @spec retain_used_vertices(map(), map()) :: map()
  def retain_used_vertices(vertices, faces) do
    used = faces |> Map.values() |> List.flatten() |> MapSet.new()
    Map.filter(vertices, fn {vertex, _position} -> MapSet.member?(used, vertex) end)
  end

  defp edge_remap(%Topology{} = source, %Topology{} = target, vertex_remap) do
    target_by_key =
      Map.new(target.edges, fn {id, edge} -> {edge_key(edge.start, edge.end), id} end)

    Map.new(source.edges, fn {source_id, edge} ->
      targets =
        for start <- Map.fetch!(vertex_remap, edge.start),
            finish <- Map.fetch!(vertex_remap, edge.end),
            target_id = Map.get(target_by_key, edge_key(start, finish)),
            target_id != nil,
            do: target_id

      {source_id, Enum.sort(Enum.uniq(targets))}
    end)
  end

  defp edge_key(left, right) when left < right, do: {left, right}
  defp edge_key(left, right), do: {right, left}
end
