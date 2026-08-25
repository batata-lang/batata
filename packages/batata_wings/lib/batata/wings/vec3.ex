defmodule Batata.Wings.Vec3 do
  @moduledoc "A closed three-component vector surface derived from `e3d_vec`."

  import Kernel, except: [length: 1]

  @type t :: {number(), number(), number()}

  @spec zero() :: t()
  def zero, do: {0.0, 0.0, 0.0}

  @spec add(t(), t()) :: t()
  def add({ax, ay, az}, {bx, by, bz}), do: {ax + bx, ay + by, az + bz}

  @spec sub(t(), t()) :: t()
  def sub({ax, ay, az}, {bx, by, bz}), do: {ax - bx, ay - by, az - bz}

  @spec scale(t(), number()) :: t()
  def scale({x, y, z}, factor), do: {x * factor, y * factor, z * factor}

  @spec dot(t(), t()) :: number()
  def dot({ax, ay, az}, {bx, by, bz}), do: ax * bx + ay * by + az * bz

  @spec cross(t(), t()) :: t()
  def cross({ax, ay, az}, {bx, by, bz}) do
    {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx}
  end

  @spec length(t()) :: float()
  def length(vector), do: :math.sqrt(dot(vector, vector))

  @spec normalize(t()) :: t()
  def normalize(vector) do
    magnitude = length(vector)
    if magnitude == 0.0, do: zero(), else: scale(vector, 1.0 / magnitude)
  end

  @spec average([t()]) :: t()
  def average([]), do: zero()

  def average(vectors) do
    vectors
    |> Enum.reduce(zero(), &add/2)
    |> scale(1.0 / Kernel.length(vectors))
  end
end
