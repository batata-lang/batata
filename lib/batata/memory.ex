defmodule Batata.Memory do
  @moduledoc """
  Versioned data model for proof-carrying memory analysis.

  This namespace deliberately separates Batata's allocation, region, escape,
  and lifetime facts from MLIR's physical read/write/allocate/free effects.
  """

  alias Batata.Memory.CanonicalJSON

  @doc "Encodes a JSON-ready value with sorted object keys and no insignificant whitespace."
  @spec canonical_json(term()) :: String.t()
  defdelegate canonical_json(value), to: CanonicalJSON, as: :encode!

  @doc "Returns a lowercase SHA-256 digest of a canonical JSON-ready value."
  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
