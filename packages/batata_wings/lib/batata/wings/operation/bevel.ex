defmodule Batata.Wings.Operation.Bevel do
  @moduledoc "Segments-one bevel of a selected planar face boundary."

  alias Batata.Wings.{IdentityDelta, Mesh}
  alias Batata.Wings.Operation.Inset

  @spec apply!(Mesh.t(), [Mesh.face_id()], map(), pos_integer()) ::
          {Mesh.t(), IdentityDelta.t(), boolean()}
  def apply!(%Mesh{} = mesh, face_ids, arguments, quota_bytes) do
    Inset.bevel!(mesh, face_ids, arguments, quota_bytes)
  end
end
