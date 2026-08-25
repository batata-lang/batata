defmodule Batata.Wings.IdentityDelta do
  @moduledoc "Stable entity provenance across one topology edit."

  alias Batata.Wings.Mesh

  @enforce_keys [:vertices, :edges, :faces, :created, :deleted]
  defstruct @enforce_keys

  @type entity_map :: %{non_neg_integer() => [non_neg_integer()]}
  @type entity_ids :: %{
          vertices: [non_neg_integer()],
          edges: [non_neg_integer()],
          faces: [non_neg_integer()]
        }
  @type t :: %__MODULE__{
          vertices: entity_map(),
          edges: entity_map(),
          faces: entity_map(),
          created: entity_ids(),
          deleted: entity_ids()
        }

  @spec identity(Mesh.t(), [non_neg_integer()]) :: t()
  def identity(%Mesh{} = mesh, edge_ids \\ []) do
    new!(
      identity_map(Map.keys(mesh.vertices)),
      identity_map(edge_ids),
      identity_map(Map.keys(mesh.faces)),
      empty_entities(),
      empty_entities()
    )
  end

  @spec new!(entity_map(), entity_map(), entity_map(), entity_ids(), entity_ids()) :: t()
  def new!(vertices, edges, faces, created, deleted) do
    %__MODULE__{
      vertices: normalize_map(vertices),
      edges: normalize_map(edges),
      faces: normalize_map(faces),
      created: normalize_entities(created),
      deleted: normalize_entities(deleted)
    }
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = delta) do
    %{
      "created" => entity_map(delta.created),
      "deleted" => entity_map(delta.deleted),
      "edges" => remap_list(delta.edges),
      "faces" => remap_list(delta.faces),
      "vertices" => remap_list(delta.vertices)
    }
  end

  @spec empty_entities() :: entity_ids()
  def empty_entities, do: %{vertices: [], edges: [], faces: []}

  defp identity_map(ids), do: Map.new(ids, &{&1, [&1]})

  defp normalize_map(remap) when is_map(remap) do
    Map.new(remap, fn {source, targets} ->
      unless valid_id?(source) and is_list(targets) and Enum.all?(targets, &valid_id?/1) do
        raise ArgumentError, "identity remap must contain non-negative integer IDs"
      end

      {source, Enum.sort(Enum.uniq(targets))}
    end)
  end

  defp normalize_entities(entities) when is_map(entities) do
    Map.new([:vertices, :edges, :faces], fn kind ->
      ids = Map.fetch!(entities, kind)

      unless is_list(ids) and Enum.all?(ids, &valid_id?/1) do
        raise ArgumentError, "#{kind} identity set must contain non-negative integer IDs"
      end

      {kind, Enum.sort(Enum.uniq(ids))}
    end)
  end

  defp remap_list(remap) do
    remap
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {source, targets} -> %{"source" => source, "targets" => targets} end)
  end

  defp entity_map(entities) do
    %{
      "edges" => entities.edges,
      "faces" => entities.faces,
      "vertices" => entities.vertices
    }
  end

  defp valid_id?(id), do: is_integer(id) and id >= 0
end
