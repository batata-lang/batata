defmodule Batata.Wings.EditResult do
  @moduledoc "The canonical output of one atomic editor transaction."

  alias Batata.Wings.{EditorState, IdentityDelta, Selection}

  @enforce_keys [
    :mesh,
    :selection,
    :generation,
    :id_remap,
    :created,
    :deleted,
    :receipt,
    :changed
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mesh: Batata.Wings.Mesh.t(),
          selection: Batata.Wings.Selection.t(),
          generation: non_neg_integer(),
          id_remap: IdentityDelta.t(),
          created: IdentityDelta.entity_ids(),
          deleted: IdentityDelta.entity_ids(),
          receipt: map(),
          changed: boolean()
        }

  @spec new!(EditorState.t(), IdentityDelta.t(), map(), boolean()) :: t()
  def new!(%EditorState{} = state, %IdentityDelta{} = delta, receipt, changed) do
    %__MODULE__{
      mesh: state.mesh,
      selection: state.selection,
      generation: state.geometry_generation,
      id_remap: delta,
      created: delta.created,
      deleted: delta.deleted,
      receipt: receipt,
      changed: changed
    }
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = result) do
    identity = IdentityDelta.canonical_map(result.id_remap)

    %{
      "changed" => result.changed,
      "created" => identity["created"],
      "deleted" => identity["deleted"],
      "generation" => result.generation,
      "identity_delta" => identity,
      "mesh_digest" => Batata.Wings.digest(result.mesh),
      "receipt" => result.receipt,
      "selection" => Selection.canonical_map(result.selection)
    }
  end
end
