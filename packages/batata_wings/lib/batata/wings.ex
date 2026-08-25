defmodule Batata.Wings do
  @moduledoc """
  A provenance-tracked, headless geometry kernel derived from Wings3D.

  The package deliberately excludes the upstream wx and OpenGL shells. Its
  public boundary is a canonical, replayable mesh value that can be compiled
  by Batata independently of any renderer or editor host.
  """

  alias Batata.Wings.{CanonicalJSON, Mesh, Provenance}

  @doc "Returns the pinned Wings3D source identity for this port."
  @spec provenance() :: map()
  defdelegate provenance, to: Provenance

  @doc "Returns a deterministic JSON representation of a mesh."
  @spec canonical_json(Mesh.t()) :: binary()
  def canonical_json(%Mesh{} = mesh), do: mesh |> Mesh.canonical_map() |> CanonicalJSON.encode!()

  @doc "Returns the SHA-256 digest of the canonical mesh JSON."
  @spec digest(Mesh.t()) :: binary()
  def digest(%Mesh{} = mesh) do
    mesh
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
