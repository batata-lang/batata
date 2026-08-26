defmodule Batata.Wings.Godot.Source do
  @moduledoc "Builds deterministic Batata source for a closed mesh materialization unit."

  alias Batata.Wings.Godot.Surface

  @spec for_surface(Surface.t(), String.t(), map()) :: String.t()
  def for_surface(%Surface{} = surface, mesh_digest, metadata \\ %{})
      when is_binary(mesh_digest) do
    descriptor = surface |> Surface.descriptor() |> inspect(limit: :infinity, width: :infinity)
    generation = Map.get(metadata, :generation, 0)
    selection_indices = Map.get(metadata, :selection_indices, [])
    state_digest = Map.get(metadata, :state_digest, mesh_digest)
    input_schema_digest = Map.get(metadata, :input_schema_digest, "")
    state_snapshot = Map.get(metadata, :state_snapshot, "")
    state_literal = inspect(state_snapshot, limit: :infinity, printable_limit: :infinity)

    """
    defmodule BatataWingsMeshNative do
      # source mesh sha256: #{mesh_digest}
      def main(), do: 0
      def subdivided_cube(), do: #{descriptor}
      def materialize(surface), do: surface
      def mesh(), do: materialize(subdivided_cube())
      def state_generation(), do: #{generation}
      def displayed_mesh_digest(), do: #{inspect(state_digest)}
      def selected_triangle_indices(), do: #{inspect(selection_indices, limit: :infinity)}
      def input_schema_digest(), do: #{inspect(input_schema_digest)}
      def editor_state_snapshot(state) do
        if state == nil do
          {{#{generation}, #{state_literal}}, #{state_literal}}
        else
          {state, #{state_literal}}
        end
      end
      def editor_pointer_button(_position, _button, _pressed, _modifiers, _ray_origin, _ray_direction, expected_generation), do: expected_generation
      def editor_key_chord(_key, _modifiers, _pressed, expected_generation), do: expected_generation
    end
    """
  end
end
