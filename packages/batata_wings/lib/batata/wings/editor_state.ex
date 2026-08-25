defmodule Batata.Wings.EditorState do
  @moduledoc "The renderer-independent state of one transactional Wings editing session."

  alias Batata.Wings.{CanonicalJSON, History, Mesh, Selection}

  @enforce_keys [
    :mesh,
    :selection,
    :history,
    :geometry_generation,
    :selection_revision,
    :last_receipt
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mesh: Mesh.t(),
          selection: Selection.t(),
          history: History.t(),
          geometry_generation: non_neg_integer(),
          selection_revision: non_neg_integer(),
          last_receipt: map() | nil
        }

  @spec new!(Mesh.t(), keyword()) :: t()
  def new!(%Mesh{} = mesh, options \\ []) do
    generation = Keyword.get(options, :generation, 0)
    selection_revision = Keyword.get(options, :selection_revision, 0)

    unless is_integer(generation) and generation >= 0 and is_integer(selection_revision) and
             selection_revision >= 0 do
      raise ArgumentError, "editor generations must be non-negative integers"
    end

    %__MODULE__{
      mesh: mesh,
      selection:
        Selection.new!(mesh, Keyword.get(options, :face_ids, []), generation, selection_revision),
      history: History.new!(Keyword.take(options, [:max_entries, :max_bytes])),
      geometry_generation: generation,
      selection_revision: selection_revision,
      last_receipt: nil
    }
  end

  @spec core_map(t()) :: map()
  def core_map(%__MODULE__{} = state) do
    %{
      "geometry_generation" => state.geometry_generation,
      "mesh" => Mesh.canonical_map(state.mesh),
      "mesh_digest" => Batata.Wings.digest(state.mesh),
      "selection" => Selection.canonical_map(state.selection),
      "selection_revision" => state.selection_revision
    }
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = state) do
    state
    |> core_map()
    |> Map.put("history", History.canonical_map(state.history))
    |> Map.put("last_receipt", state.last_receipt)
  end

  @spec digest(t()) :: binary()
  def digest(%__MODULE__{} = state) do
    state
    |> core_map()
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
