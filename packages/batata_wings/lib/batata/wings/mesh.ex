defmodule Batata.Wings.Mesh do
  @moduledoc "A renderer-independent polygon mesh with stable integer identities."

  alias Batata.Wings.Diagnostic

  @enforce_keys [:vertices, :faces]
  defstruct vertices: %{}, faces: %{}, metadata: %{}

  @type vertex_id :: non_neg_integer()
  @type face_id :: non_neg_integer()
  @type position :: Batata.Wings.Vec3.t()
  @type t :: %__MODULE__{
          vertices: %{vertex_id() => position()},
          faces: %{face_id() => [vertex_id()]},
          metadata: map()
        }

  @spec new!(map(), map(), map()) :: t()
  def new!(vertices, faces, metadata \\ %{}) do
    mesh = %__MODULE__{vertices: vertices, faces: faces, metadata: metadata}
    validate_identity_surface!(mesh)
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = mesh) do
    %{
      "faces" =>
        mesh.faces
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {id, vertices} -> %{"id" => id, "vertices" => vertices} end),
      "metadata" => mesh.metadata,
      "vertices" =>
        mesh.vertices
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {id, {x, y, z}} -> %{"id" => id, "position" => [x, y, z]} end)
    }
  end

  defp validate_identity_surface!(%__MODULE__{} = mesh) do
    invalid_vertex = Enum.find(mesh.vertices, &(not valid_vertex?(&1)))
    invalid_face = Enum.find(mesh.faces, &(not valid_face?(&1, mesh.vertices)))

    if invalid_vertex || invalid_face do
      raise Diagnostic.new!(
              "E_WINGS_TOPOLOGY_INCONSISTENT",
              "mesh identity surface is invalid",
              %{"face" => inspect(invalid_face), "vertex" => inspect(invalid_vertex)},
              [%{"command" => "repair vertex and face identities before building topology"}]
            )
    end

    mesh
  end

  defp valid_vertex?({id, {x, y, z}}) do
    is_integer(id) and id >= 0 and is_number(x) and is_number(y) and is_number(z)
  end

  defp valid_vertex?(_vertex), do: false

  defp valid_face?({id, vertices}, positions) do
    is_integer(id) and id >= 0 and is_list(vertices) and Kernel.length(vertices) >= 3 and
      Enum.all?(vertices, &Map.has_key?(positions, &1))
  end

  defp valid_face?(_face, _positions), do: false
end
