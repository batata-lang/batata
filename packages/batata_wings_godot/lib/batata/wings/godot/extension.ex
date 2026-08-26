defmodule Batata.Wings.Godot.Extension do
  @moduledoc false

  use Batata.Godot.Extension,
    extension: "batata_wings_mesh",
    compatibility_minimum: "4.6.2",
    initialization_level: :scene

  godot_class("BatataWingsMesh", base: "RefCounted")
  godot_outbound(:array_mesh_surface)

  godot_method(:mesh,
    args: [],
    returns: {:object, "ArrayMesh"},
    outbound: :array_mesh_surface,
    state: :replace
  )

  godot_method(:state_generation, args: [], returns: :int, state: :replace)
  godot_method(:displayed_mesh_code, args: [], returns: :int, state: :replace)

  godot_method(:selected_triangle_indices,
    args: [],
    returns: :packed_int32_array,
    state: :replace
  )

  godot_method(:editor_pointer_button,
    args: [:int, :int, :int, :int, :int, :int, :int],
    returns: :int,
    state: :replace
  )

  godot_method(:editor_move,
    args: [:int, :int, :int, :int, :int],
    returns: :int,
    state: :replace
  )

  godot_method(:editor_undo, args: [:int], returns: :int, state: :replace)
  godot_method(:editor_redo, args: [:int], returns: :int, state: :replace)

  def mesh(_state), do: nil
  def state_generation(_state), do: 0
  def displayed_mesh_code(_state), do: 0
  def selected_triangle_indices(_state), do: []

  def editor_pointer_button(
        _state,
        _event_word,
        _origin_x,
        _origin_y,
        _origin_z,
        _direction_x,
        _direction_y,
        _direction_z
      ),
      do: 0

  def editor_move(
        _position,
        _dx,
        _dy,
        _dz,
        _expected_generation,
        _quota_bytes
      ),
      do: 0

  def editor_undo(_state, _expected_generation), do: 0
  def editor_redo(_state, _expected_generation), do: 0
end
