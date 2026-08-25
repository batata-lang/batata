defmodule Batata.Wings.Selection do
  @moduledoc "A generation-bound canonical face selection."

  alias Batata.Wings.{CanonicalJSON, Diagnostic, Mesh}

  @enforce_keys [:mode, :face_ids, :mesh_digest, :geometry_generation, :revision]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mode: :face,
          face_ids: [Mesh.face_id()],
          mesh_digest: binary(),
          geometry_generation: non_neg_integer(),
          revision: non_neg_integer()
        }

  @spec new!(Mesh.t(), [Mesh.face_id()], non_neg_integer(), non_neg_integer()) :: t()
  def new!(%Mesh{} = mesh, face_ids \\ [], geometry_generation \\ 0, revision \\ 0) do
    normalized = normalize_ids!(face_ids)
    validate_faces!(mesh, normalized)

    %__MODULE__{
      mode: :face,
      face_ids: normalized,
      mesh_digest: Batata.Wings.digest(mesh),
      geometry_generation: geometry_generation,
      revision: revision
    }
  end

  @spec bind!(t(), Mesh.t(), non_neg_integer(), [Mesh.face_id()]) :: t()
  def bind!(%__MODULE__{} = selection, %Mesh{} = mesh, generation, face_ids) do
    new!(mesh, face_ids, generation, selection.revision + 1)
  end

  @spec update!(t(), Mesh.t(), non_neg_integer(), :replace | :add | :remove | :toggle | :clear, [
          Mesh.face_id()
        ]) ::
          t()
  def update!(%__MODULE__{} = selection, %Mesh{} = mesh, generation, operation, face_ids \\ []) do
    validate!(selection, mesh, generation)
    incoming = normalize_ids!(face_ids)
    validate_faces!(mesh, incoming)

    updated =
      case operation do
        :replace -> incoming
        :add -> Enum.sort(Enum.uniq(selection.face_ids ++ incoming))
        :remove -> selection.face_ids -- incoming
        :toggle -> toggle(selection.face_ids, incoming)
        :clear -> []
        _ -> invalid_selection!(face_ids, [], "unknown selection operation #{inspect(operation)}")
      end

    if updated == selection.face_ids do
      selection
    else
      bind!(selection, mesh, generation, updated)
    end
  end

  @spec validate!(t(), Mesh.t(), non_neg_integer()) :: t()
  def validate!(%__MODULE__{} = selection, %Mesh{} = mesh, generation) do
    digest = Batata.Wings.digest(mesh)

    if selection.geometry_generation != generation or selection.mesh_digest != digest do
      raise Diagnostic.new!(
              "E_WINGS_SELECTION_STALE",
              "selection belongs to a different mesh generation",
              %{
                "expected_generation" => generation,
                "expected_mesh_digest" => digest,
                "observed_generation" => selection.geometry_generation,
                "observed_mesh_digest" => selection.mesh_digest,
                "selection_digest" => digest(selection)
              },
              [%{"command" => "re-pick faces against the current mesh generation"}],
              true
            )
    end

    validate_faces!(mesh, selection.face_ids)
    selection
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = selection) do
    %{
      "face_ids" => selection.face_ids,
      "geometry_generation" => selection.geometry_generation,
      "mesh_digest" => selection.mesh_digest,
      "mode" => Atom.to_string(selection.mode),
      "revision" => selection.revision
    }
  end

  @spec digest(t()) :: binary()
  def digest(%__MODULE__{} = selection) do
    %{"face_ids" => selection.face_ids, "mode" => Atom.to_string(selection.mode)}
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_ids!(face_ids) when is_list(face_ids) do
    unless Enum.all?(face_ids, &(is_integer(&1) and &1 >= 0)) do
      invalid_selection!(face_ids, [], "face IDs must be non-negative integers")
    end

    face_ids |> Enum.uniq() |> Enum.sort()
  end

  defp normalize_ids!(face_ids),
    do: invalid_selection!(face_ids, [], "face selection must be a list")

  defp validate_faces!(mesh, face_ids) do
    missing = Enum.reject(face_ids, &Map.has_key?(mesh.faces, &1))

    if missing != [] do
      invalid_selection!(face_ids, missing, "selection references missing faces")
    end
  end

  defp toggle(current, incoming) do
    Enum.reduce(incoming, current, fn face, selected ->
      if face in selected, do: selected -- [face], else: Enum.sort([face | selected])
    end)
  end

  defp invalid_selection!(face_ids, missing, message) do
    raise Diagnostic.new!(
            "E_WINGS_SELECTION_INVALID",
            message,
            %{"face_ids" => inspect(face_ids), "missing_face_ids" => missing},
            [%{"command" => "select only canonical face IDs from the current mesh"}],
            true
          )
  end
end
