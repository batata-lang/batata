defmodule Batata.Wings.Picking do
  @moduledoc "Deterministic CPU ray picking over canonical polygon faces."

  alias Batata.Wings.{Diagnostic, Mesh, Vec3}

  @default_epsilon 1.0e-9

  @type hit :: %{
          face_id: Mesh.face_id(),
          triangle_ordinal: non_neg_integer(),
          distance: float(),
          position: Vec3.t()
        }

  @spec pick_face(Mesh.t(), Vec3.t(), Vec3.t(), keyword()) :: {:hit, hit()} | :miss
  def pick_face(%Mesh{} = mesh, origin, direction, options \\ []) do
    epsilon = Keyword.get(options, :epsilon, @default_epsilon)
    backfaces = Keyword.get(options, :backfaces, :both)
    validate_ray!(origin, direction, epsilon, backfaces)
    ray = Vec3.normalize(direction)

    hits =
      mesh.faces
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {face_id, vertex_ids} ->
        face_hits(mesh, face_id, vertex_ids, origin, ray, epsilon, backfaces)
      end)

    case hits do
      [] ->
        :miss

      _hits ->
        minimum = hits |> Enum.map(& &1.distance) |> Enum.min()

        hit =
          hits
          |> Enum.filter(&(&1.distance <= minimum + epsilon))
          |> Enum.min_by(&{&1.face_id, &1.triangle_ordinal})

        {:hit, Map.put(hit, :position, Vec3.add(origin, Vec3.scale(ray, hit.distance)))}
    end
  end

  defp triangulate([first, second, third | rest]) do
    [{first, second, third} | triangulate_fan(first, third, rest)]
  end

  defp triangulate_fan(_first, _previous, []), do: []

  defp triangulate_fan(first, previous, [next | rest]) do
    [{first, previous, next} | triangulate_fan(first, next, rest)]
  end

  defp face_hits(mesh, face_id, vertex_ids, origin, ray, epsilon, backfaces) do
    vertex_ids
    |> triangulate()
    |> Enum.with_index()
    |> Enum.flat_map(fn {triangle, ordinal} ->
      case intersect(mesh, triangle, origin, ray, epsilon, backfaces) do
        nil -> []
        distance -> [%{face_id: face_id, triangle_ordinal: ordinal, distance: distance}]
      end
    end)
  end

  defp intersect(mesh, {a_id, b_id, c_id}, origin, direction, epsilon, backfaces) do
    a = Map.fetch!(mesh.vertices, a_id)
    b = Map.fetch!(mesh.vertices, b_id)
    c = Map.fetch!(mesh.vertices, c_id)
    edge_ab = Vec3.sub(b, a)
    edge_ac = Vec3.sub(c, a)
    p = Vec3.cross(direction, edge_ac)
    determinant = Vec3.dot(edge_ab, p)

    if parallel_or_hidden?(determinant, epsilon, backfaces) do
      nil
    else
      inverse = 1.0 / determinant
      translated = Vec3.sub(origin, a)
      u = Vec3.dot(translated, p) * inverse
      q = Vec3.cross(translated, edge_ab)
      v = Vec3.dot(direction, q) * inverse
      distance = Vec3.dot(edge_ac, q) * inverse

      if u >= -epsilon and v >= -epsilon and u + v <= 1.0 + epsilon and distance > epsilon,
        do: distance,
        else: nil
    end
  end

  defp parallel_or_hidden?(determinant, epsilon, :both), do: abs(determinant) <= epsilon
  defp parallel_or_hidden?(determinant, epsilon, :front), do: determinant <= epsilon

  defp validate_ray!(origin, direction, epsilon, backfaces) do
    valid =
      valid_vector?(origin) and valid_vector?(direction) and Vec3.length(direction) > 0.0 and
        is_number(epsilon) and epsilon > 0 and backfaces in [:both, :front]

    unless valid do
      raise Diagnostic.new!(
              "E_WINGS_EDIT_PRECONDITION_FAILED",
              "picking ray does not satisfy the closed input schema",
              %{
                "backfaces" => inspect(backfaces),
                "direction" => inspect(direction),
                "epsilon" => inspect(epsilon),
                "origin" => inspect(origin)
              },
              [%{"command" => "provide finite origin/direction and a positive epsilon"}]
            )
    end
  end

  defp valid_vector?({x, y, z}), do: Enum.all?([x, y, z], &finite_number?/1)
  defp valid_vector?(_value), do: false

  defp finite_number?(value) when is_integer(value), do: abs(value) < 1.0e308

  defp finite_number?(value) when is_float(value) do
    :erlang.float_to_binary(value) not in ["nan", "inf", "-inf"] and abs(value) < 1.0e308
  end

  defp finite_number?(_value), do: false
end
