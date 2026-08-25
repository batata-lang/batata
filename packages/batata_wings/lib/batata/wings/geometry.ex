defmodule Batata.Wings.Geometry do
  @moduledoc false

  alias Batata.Wings.{Diagnostic, Mesh, Vec3}

  @epsilon 1.0e-12

  @spec face_normal!(Mesh.t(), Mesh.face_id()) :: Vec3.t()
  def face_normal!(%Mesh{} = mesh, face_id) do
    vertices = mesh.faces |> Map.fetch!(face_id) |> Enum.map(&Map.fetch!(mesh.vertices, &1))
    normal = newell(vertices)

    if Vec3.length(normal) <= @epsilon do
      geometry_error!("E_WINGS_EDIT_WOULD_DEGENERATE", "face has zero area", mesh, %{
        "face_id" => face_id
      })
    end

    Vec3.normalize(normal)
  end

  @spec validate!(Mesh.t(), binary()) :: Mesh.t()
  def validate!(%Mesh{} = mesh, operation) do
    invalid_vertex =
      Enum.find(mesh.vertices, fn {_id, position} -> not finite_vector?(position) end)

    if invalid_vertex do
      geometry_error!("E_WINGS_EDIT_NON_FINITE", "edit produced a non-finite vertex", mesh, %{
        "operation" => operation,
        "vertex" => inspect(invalid_vertex)
      })
    end

    Enum.each(Map.keys(mesh.faces), &face_normal!(mesh, &1))
    mesh
  end

  @spec finite_vector?(term()) :: boolean()
  def finite_vector?({x, y, z}), do: Enum.all?([x, y, z], &finite_number?/1)
  def finite_vector?(_value), do: false

  @spec estimate_bytes(Mesh.t()) :: non_neg_integer()
  def estimate_bytes(%Mesh{} = mesh) do
    corners = mesh.faces |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    map_size(mesh.vertices) * 32 + map_size(mesh.faces) * 48 + corners * 16
  end

  defp newell(vertices) do
    Enum.zip(vertices, tl(vertices) ++ [hd(vertices)])
    |> Enum.reduce(Vec3.zero(), fn {{x1, y1, z1}, {x2, y2, z2}}, {nx, ny, nz} ->
      {
        nx + (y1 - y2) * (z1 + z2),
        ny + (z1 - z2) * (x1 + x2),
        nz + (x1 - x2) * (y1 + y2)
      }
    end)
  end

  defp geometry_error!(code, message, mesh, context) do
    raise Diagnostic.new!(
            code,
            message,
            Map.merge(
              %{
                "before_mesh_digest" => Batata.Wings.digest(mesh),
                "replay_command" => "mix test test/edit_move_test.exs --seed 0 --max-cases 1"
              },
              context
            ),
            [%{"command" => "reduce the edit distance or repair the selected geometry"}],
            true
          )
  end

  defp finite_number?(value) when is_integer(value), do: abs(value) < 1.0e308

  defp finite_number?(value) when is_float(value) do
    :erlang.float_to_binary(value) not in ["nan", "inf", "-inf"] and abs(value) < 1.0e308
  end

  defp finite_number?(_value), do: false
end
