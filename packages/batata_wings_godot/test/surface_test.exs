defmodule Batata.Wings.Godot.SurfaceTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.Godot.{Source, Surface}
  alias Batata.Wings.{Primitive, Subdivision}

  test "once-subdivided cube becomes a deterministic fixed-point triangle surface" do
    mesh = Primitive.cube() |> Subdivision.smooth!()
    surface = Surface.from_mesh!(mesh, scale: 36)

    assert length(surface.vertices) == 26
    assert length(surface.indices) == 144
    assert surface.scale == 36
    assert Enum.min(surface.indices) == 0
    assert Enum.max(surface.indices) == 25

    receipt = Surface.receipt(surface)
    assert receipt["triangle_count"] == 48
    assert byte_size(receipt["descriptor_sha256"]) == 64

    source = Source.for_surface(surface, Batata.Wings.digest(mesh))
    assert source == Source.for_surface(surface, Batata.Wings.digest(mesh))
    assert source =~ "def mesh(), do: materialize(subdivided_cube())"
    refute source =~ "Batata.Wings.Subdivision"
  end

  test "unrepresentable coordinates fail before native compilation" do
    mesh = Primitive.cube(2 / 7)

    assert_raise ArgumentError, ~r/not representable/, fn ->
      Surface.from_mesh!(mesh, scale: 36)
    end
  end
end
