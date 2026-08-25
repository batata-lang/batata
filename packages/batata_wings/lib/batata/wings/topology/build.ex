defmodule Batata.Wings.Topology.Build do
  @moduledoc "Builds a deterministic closed winged-edge topology from face loops."

  alias Batata.Wings.{Diagnostic, Mesh, Topology}
  alias Batata.Wings.Topology.Edge

  @spec build!(Mesh.t()) :: Topology.t()
  def build!(%Mesh{} = mesh) do
    sides = mesh |> face_sides!() |> Enum.group_by(& &1.key)
    keys = sides |> Map.keys() |> Enum.sort()
    edge_ids = keys |> Enum.with_index() |> Map.new()

    edges =
      keys
      |> Enum.map(fn key -> build_edge!(key, Map.fetch!(sides, key), edge_ids) end)
      |> Map.new(&{&1.id, &1})

    topology = %Topology{
      mesh: mesh,
      edges: edges,
      face_edges: face_edges(mesh, edge_ids),
      vertex_edges: vertex_edges(mesh, edges)
    }

    Topology.validate!(topology)
  end

  defp face_sides!(%Mesh{} = mesh) do
    mesh.faces
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {face_id, vertices} ->
      if Enum.uniq(vertices) != vertices do
        topology_error!("face repeats a vertex", %{"face" => face_id, "vertices" => vertices})
      end

      side_keys = Enum.map(cyclic_pairs(vertices), fn {from, to} -> edge_key(from, to) end)

      cyclic_triples(side_keys)
      |> Enum.zip(cyclic_pairs(vertices))
      |> Enum.map(fn {{previous, key, following}, {from, to}} ->
        %{face: face_id, from: from, to: to, key: key, previous: previous, following: following}
      end)
    end)
  end

  defp build_edge!(key, [first, second], edge_ids) do
    {start, finish} = key

    {left, right} =
      case {first.from, first.to, second.from, second.to} do
        {^start, ^finish, ^finish, ^start} -> {first, second}
        {^finish, ^start, ^start, ^finish} -> {second, first}
        _ -> non_manifold!(key, [first, second])
      end

    %Edge{
      id: Map.fetch!(edge_ids, key),
      start: start,
      end: finish,
      left_face: left.face,
      right_face: right.face,
      left_prev: Map.fetch!(edge_ids, left.previous),
      left_next: Map.fetch!(edge_ids, left.following),
      right_prev: Map.fetch!(edge_ids, right.previous),
      right_next: Map.fetch!(edge_ids, right.following)
    }
  end

  defp build_edge!(key, occurrences, _edge_ids), do: non_manifold!(key, occurrences)

  defp face_edges(mesh, edge_ids) do
    Map.new(mesh.faces, fn {face_id, vertices} ->
      {face_id,
       Enum.map(cyclic_pairs(vertices), fn {from, to} ->
         Map.fetch!(edge_ids, edge_key(from, to))
       end)}
    end)
  end

  defp vertex_edges(mesh, edges) do
    initial = Map.new(mesh.vertices, fn {vertex_id, _position} -> {vertex_id, []} end)

    Enum.reduce(edges, initial, fn {edge_id, edge}, index ->
      index
      |> Map.update!(edge.start, &[edge_id | &1])
      |> Map.update!(edge.end, &[edge_id | &1])
    end)
    |> Map.new(fn {vertex_id, edge_ids} -> {vertex_id, Enum.sort(edge_ids)} end)
  end

  defp cyclic_pairs([first | rest] = values) do
    Enum.zip(values, rest ++ [first])
  end

  defp cyclic_triples(values) do
    previous = [List.last(values) | Enum.drop(values, -1)]
    following = tl(values) ++ [hd(values)]
    Enum.zip([previous, values, following])
  end

  defp edge_key(left, right) when left < right, do: {left, right}
  defp edge_key(left, right) when left > right, do: {right, left}

  defp edge_key(vertex, vertex),
    do: topology_error!("face contains a zero-length edge", %{"vertex" => vertex})

  defp non_manifold!(key, occurrences) do
    raise Diagnostic.new!(
            "E_WINGS_NON_MANIFOLD_EDGE",
            "an edge must have exactly two oppositely oriented face uses",
            %{
              "edge" => Tuple.to_list(key),
              "occurrences" => Enum.map(occurrences, &Map.take(&1, [:face, :from, :to]))
            }
          )
  end

  defp topology_error!(message, context) do
    raise Diagnostic.new!("E_WINGS_TOPOLOGY_INCONSISTENT", message, context)
  end
end
