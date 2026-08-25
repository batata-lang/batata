defmodule Batata.Wings.Godot.Extension do
  @moduledoc false

  use Batata.Godot.Extension,
    extension: "batata_wings_mesh",
    compatibility_minimum: "4.6.2",
    initialization_level: :scene

  godot_class("BatataWingsMesh", base: "RefCounted")
  godot_outbound(:array_mesh_surface)
  godot_method(:mesh, args: [], returns: {:object, "ArrayMesh"}, outbound: :array_mesh_surface)
  godot_method(:state_generation, args: [], returns: :int)
  godot_method(:displayed_mesh_digest, args: [], returns: :string)
  godot_method(:selected_triangle_indices, args: [], returns: :packed_int32_array)
  godot_method(:input_schema_digest, args: [], returns: :string)
  godot_method(:editor_state_snapshot, args: [], returns: :string, state: :replace)

  godot_method(:editor_pointer_button,
    args: [:vector2, :int, :bool, :int, :vector3, :vector3, :int],
    returns: :int
  )

  godot_method(:editor_key_chord, args: [:int, :int, :bool, :int], returns: :int)

  def mesh, do: nil
  def state_generation, do: 0
  def displayed_mesh_digest, do: ""
  def selected_triangle_indices, do: []
  def input_schema_digest, do: ""
  def editor_state_snapshot(_state), do: ""

  def editor_pointer_button(
        _position,
        _button,
        _pressed,
        _modifiers,
        _ray_origin,
        _ray_direction,
        expected_generation
      ),
      do: expected_generation

  def editor_key_chord(_key, _modifiers, _pressed, expected_generation),
    do: expected_generation
end
