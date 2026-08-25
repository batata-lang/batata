defmodule Batata.Wings.Topology do
  @moduledoc "A closed winged-edge topology projected from a polygon mesh."

  alias Batata.Wings.{CanonicalJSON, Diagnostic, Mesh}

  defmodule Edge do
    @moduledoc "One canonical edge and its left/right face traversal links."

    @enforce_keys [
      :id,
      :start,
      :end,
      :left_face,
      :right_face,
      :left_prev,
      :left_next,
      :right_prev,
      :right_next
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: non_neg_integer(),
            start: non_neg_integer(),
            end: non_neg_integer(),
            left_face: non_neg_integer(),
            right_face: non_neg_integer(),
            left_prev: non_neg_integer(),
            left_next: non_neg_integer(),
            right_prev: non_neg_integer(),
            right_next: non_neg_integer()
          }
  end

  @enforce_keys [:mesh, :edges, :face_edges, :vertex_edges]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mesh: Mesh.t(),
          edges: %{non_neg_integer() => Edge.t()},
          face_edges: %{non_neg_integer() => [non_neg_integer()]},
          vertex_edges: %{non_neg_integer() => [non_neg_integer()]}
        }

  @spec stats(t()) :: map()
  def stats(%__MODULE__{} = topology) do
    vertices = map_size(topology.mesh.vertices)
    edges = map_size(topology.edges)
    faces = map_size(topology.mesh.faces)

    %{
      "closed" =>
        Enum.all?(topology.edges, fn {_id, edge} -> edge.left_face != edge.right_face end),
      "edges" => edges,
      "euler_characteristic" => vertices - edges + faces,
      "faces" => faces,
      "vertices" => vertices
    }
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = topology) do
    invalid = Enum.find(topology.edges, fn {_id, edge} -> not valid_edge?(edge, topology) end)

    if invalid do
      raise Diagnostic.new!(
              "E_WINGS_TOPOLOGY_INCONSISTENT",
              "winged-edge traversal links do not close",
              %{"edge" => inspect(invalid), "mesh_digest" => Batata.Wings.digest(topology.mesh)}
            )
    end

    topology
  end

  @spec digest(t()) :: binary()
  def digest(%__MODULE__{} = topology) do
    topology
    |> canonical_map()
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = topology) do
    %{
      "edges" =>
        topology.edges
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_id, edge} -> Map.from_struct(edge) end),
      "mesh" => Mesh.canonical_map(topology.mesh),
      "stats" => stats(topology)
    }
  end

  defp valid_edge?(%Edge{} = edge, topology) do
    edge.id >= 0 and edge.start != edge.end and edge.left_face != edge.right_face and
      Map.has_key?(topology.mesh.vertices, edge.start) and
      Map.has_key?(topology.mesh.vertices, edge.end) and
      edge.id in Map.fetch!(topology.face_edges, edge.left_face) and
      edge.id in Map.fetch!(topology.face_edges, edge.right_face) and
      Enum.all?(
        [edge.left_prev, edge.left_next, edge.right_prev, edge.right_next],
        &Map.has_key?(topology.edges, &1)
      )
  end
end
