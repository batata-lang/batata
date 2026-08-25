defmodule Batata.Wings.Godot.Extension do
  @moduledoc false

  use Batata.Godot.Extension,
    extension: "batata_wings_mesh",
    compatibility_minimum: "4.6.2",
    initialization_level: :scene

  godot_class("BatataWingsMesh", base: "RefCounted")
  godot_outbound(:array_mesh_surface)
  godot_method(:mesh, args: [], returns: {:object, "ArrayMesh"}, outbound: :array_mesh_surface)

  def mesh, do: nil
end
