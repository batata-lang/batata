defmodule Batata.Wings.Primitive do
  @moduledoc "Deterministic primitive meshes used to close geometry pipelines."

  alias Batata.Wings.Mesh

  @spec cube(number()) :: Mesh.t()
  def cube(size \\ 2.0) when is_number(size) and size > 0 do
    half = size / 2

    Mesh.new!(
      %{
        0 => {-half, -half, -half},
        1 => {half, -half, -half},
        2 => {half, half, -half},
        3 => {-half, half, -half},
        4 => {-half, -half, half},
        5 => {half, -half, half},
        6 => {half, half, half},
        7 => {-half, half, half}
      },
      %{
        0 => [0, 3, 2, 1],
        1 => [4, 5, 6, 7],
        2 => [0, 1, 5, 4],
        3 => [1, 2, 6, 5],
        4 => [2, 3, 7, 6],
        5 => [3, 0, 4, 7]
      },
      %{"primitive" => "cube", "size" => size, "subdivision_level" => 0}
    )
  end
end
