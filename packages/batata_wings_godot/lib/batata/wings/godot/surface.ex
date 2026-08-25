defmodule Batata.Wings.Godot.Surface do
  @moduledoc "A closed fixed-point ArrayMesh surface descriptor."

  alias Batata.Wings.{CanonicalJSON, Mesh, Selection}

  @enforce_keys [:vertices, :indices, :triangle_faces, :scale]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          vertices: [{integer(), integer(), integer()}],
          indices: [non_neg_integer()],
          triangle_faces: [Mesh.face_id()],
          scale: pos_integer()
        }

  @doc "Triangulates a mesh and quantizes positions under an explicit scale."
  @spec from_mesh!(Mesh.t(), keyword()) :: t()
  def from_mesh!(%Mesh{} = mesh, options \\ []) do
    scale = Keyword.get(options, :scale, 1)
    tolerance = Keyword.get(options, :tolerance, 1.0e-12)

    unless is_integer(scale) and scale > 0 and is_number(tolerance) and tolerance >= 0 do
      raise ArgumentError, "surface scale must be positive and tolerance must be non-negative"
    end

    ordered_vertices = Enum.sort_by(mesh.vertices, &elem(&1, 0))

    vertex_indices =
      ordered_vertices |> Enum.with_index() |> Map.new(fn {{id, _}, index} -> {id, index} end)

    vertices =
      Enum.map(ordered_vertices, fn {_id, position} ->
        quantize!(position, scale, tolerance)
      end)

    triangles =
      mesh.faces
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {face, vertices} ->
        vertices
        |> triangulate!()
        |> Enum.map(&{face, &1})
      end)

    indices =
      Enum.flat_map(triangles, fn {_face, triangle} ->
        Enum.map(triangle, &Map.fetch!(vertex_indices, &1))
      end)

    %__MODULE__{
      vertices: vertices,
      indices: indices,
      triangle_faces: Enum.map(triangles, &elem(&1, 0)),
      scale: scale
    }
  end

  @doc "Returns the term consumed by Batata.Godot's closed surface codec."
  @spec descriptor(t()) :: {list(), list(), pos_integer()}
  def descriptor(%__MODULE__{} = surface) do
    {surface.vertices, surface.indices, surface.scale}
  end

  @doc "Returns triangle indices for a selection without changing canonical geometry."
  @spec selection_indices(t(), Selection.t()) :: [non_neg_integer()]
  def selection_indices(%__MODULE__{} = surface, %Selection{} = selection) do
    selected = MapSet.new(selection.face_ids)

    surface.indices
    |> Enum.chunk_every(3)
    |> Enum.zip(surface.triangle_faces)
    |> Enum.flat_map(fn {triangle, face} ->
      if MapSet.member?(selected, face), do: triangle, else: []
    end)
  end

  @doc false
  def smoke_invocation(%__MODULE__{} = surface) do
    vertices =
      Enum.map(surface.vertices, fn {x, y, z} ->
        [x / surface.scale, y / surface.scale, z / surface.scale]
      end)

    %{
      method: "mesh",
      arguments: [],
      expected: %{array_mesh: %{vertices: vertices, indices: surface.indices}}
    }
  end

  @doc "Returns the replay fields bound into the mesh receipt."
  @spec receipt(t()) :: map()
  def receipt(%__MODULE__{} = surface) do
    canonical = %{
      "indices" => surface.indices,
      "scale" => surface.scale,
      "triangle_faces" => surface.triangle_faces,
      "vertices" => Enum.map(surface.vertices, &Tuple.to_list/1)
    }

    %{
      "descriptor_sha256" => canonical |> CanonicalJSON.encode!() |> digest(),
      "index_count" => length(surface.indices),
      "scale" => surface.scale,
      "triangle_count" => div(length(surface.indices), 3),
      "triangle_face_digest" => surface.triangle_faces |> CanonicalJSON.encode!() |> digest(),
      "vertex_count" => length(surface.vertices)
    }
  end

  defp triangulate!([first, second, third | rest]) do
    [[first, second, third] | triangulate_fan(first, third, rest)]
  end

  defp triangulate!(vertices) do
    raise ArgumentError, "face requires at least three vertices, got: #{inspect(vertices)}"
  end

  defp triangulate_fan(_first, _previous, []), do: []

  defp triangulate_fan(first, previous, [next | rest]) do
    [[first, previous, next] | triangulate_fan(first, next, rest)]
  end

  defp quantize!({x, y, z}, scale, tolerance) do
    {quantize_component!(x, scale, tolerance), quantize_component!(y, scale, tolerance),
     quantize_component!(z, scale, tolerance)}
  end

  defp quantize_component!(value, scale, tolerance) do
    integer = round(value * scale)

    if abs(integer / scale - value) > tolerance do
      raise ArgumentError,
            "mesh coordinate #{inspect(value)} is not representable at fixed-point scale #{scale}"
    end

    integer
  end

  defp digest(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
