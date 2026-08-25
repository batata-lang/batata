defmodule Batata.Wings.Godot.Source do
  @moduledoc "Builds deterministic Batata source for a closed mesh materialization unit."

  alias Batata.Wings.Godot.Surface

  @spec for_surface(Surface.t(), String.t()) :: String.t()
  def for_surface(%Surface{} = surface, mesh_digest) when is_binary(mesh_digest) do
    descriptor = surface |> Surface.descriptor() |> inspect(limit: :infinity, width: :infinity)

    """
    defmodule BatataWingsMeshNative do
      # source mesh sha256: #{mesh_digest}
      def main(), do: 0
      def subdivided_cube(), do: #{descriptor}
      def materialize(surface), do: surface
      def mesh(), do: materialize(subdivided_cube())
    end
    """
  end
end
