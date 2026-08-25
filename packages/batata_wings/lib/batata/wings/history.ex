defmodule Batata.Wings.History do
  @moduledoc "A deterministic, byte- and entry-bounded geometry history."

  alias Batata.Wings.{CanonicalJSON, Diagnostic, EditorState, Mesh, Selection}
  alias Batata.Wings.Operation.Delta

  @default_max_entries 64
  @default_max_bytes 64 * 1024 * 1024

  defmodule Entry do
    @moduledoc false

    @enforce_keys [
      :mesh,
      :face_ids,
      :source_generation,
      :selection_revision,
      :command_digest,
      :receipt,
      :digest,
      :bytes
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            mesh: Batata.Wings.Mesh.t(),
            face_ids: [non_neg_integer()],
            source_generation: non_neg_integer(),
            selection_revision: non_neg_integer(),
            command_digest: binary(),
            receipt: map() | nil,
            digest: binary(),
            bytes: pos_integer()
          }
  end

  @enforce_keys [:past, :future, :bytes, :max_entries, :max_bytes, :evicted_generations]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          past: [Entry.t()],
          future: [Entry.t()],
          bytes: non_neg_integer(),
          max_entries: pos_integer(),
          max_bytes: pos_integer(),
          evicted_generations: [non_neg_integer()]
        }

  @spec new!(keyword()) :: t()
  def new!(options \\ []) do
    max_entries = Keyword.get(options, :max_entries, @default_max_entries)
    max_bytes = Keyword.get(options, :max_bytes, @default_max_bytes)

    unless is_integer(max_entries) and max_entries > 0 and is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError, "history limits must be positive integers"
    end

    %__MODULE__{
      past: [],
      future: [],
      bytes: 0,
      max_entries: max_entries,
      max_bytes: max_bytes,
      evicted_generations: []
    }
  end

  @spec push!(t(), EditorState.t(), binary(), map()) :: t()
  def push!(%__MODULE__{} = history, %EditorState{} = state, command_digest, receipt) do
    entry = entry(state, command_digest, receipt)

    if entry.bytes > history.max_bytes do
      quota_error!(history, entry.bytes, state)
    end

    history
    |> Map.put(:past, [entry | history.past])
    |> Map.put(:future, [])
    |> trim()
  end

  @spec undo!(EditorState.t(), binary()) :: {EditorState.t(), Batata.Wings.IdentityDelta.t()}
  def undo!(%EditorState{history: %__MODULE__{past: []}} = state, _command_digest) do
    empty!(state, "undo")
  end

  def undo!(%EditorState{} = state, command_digest) do
    [target | remaining] = state.history.past
    verify!(target, state)
    current = entry(state, command_digest, state.last_receipt)

    history =
      %{state.history | past: remaining, future: [current | state.history.future]}
      |> recount()

    restore(state, target, history)
  end

  @spec redo!(EditorState.t(), binary()) :: {EditorState.t(), Batata.Wings.IdentityDelta.t()}
  def redo!(%EditorState{history: %__MODULE__{future: []}} = state, _command_digest) do
    empty!(state, "redo")
  end

  def redo!(%EditorState{} = state, command_digest) do
    [target | remaining] = state.history.future
    verify!(target, state)
    current = entry(state, command_digest, state.last_receipt)

    history =
      %{state.history | past: [current | state.history.past], future: remaining}
      |> recount()

    restore(state, target, history)
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = history) do
    %{
      "bytes" => history.bytes,
      "evicted_generations" => history.evicted_generations,
      "future_entries" => Enum.map(history.future, &entry_summary/1),
      "max_bytes" => history.max_bytes,
      "max_entries" => history.max_entries,
      "past_entries" => Enum.map(history.past, &entry_summary/1)
    }
  end

  defp restore(state, target, history) do
    generation = state.geometry_generation + 1

    selection =
      Selection.new!(target.mesh, target.face_ids, generation, state.selection_revision + 1)

    restored = %{
      state
      | mesh: target.mesh,
        selection: selection,
        history: history,
        geometry_generation: generation,
        selection_revision: selection.revision,
        last_receipt: target.receipt
    }

    {restored, transition_delta(state.mesh, target.mesh)}
  end

  defp transition_delta(source, target) do
    target_vertices = target.vertices |> Map.keys() |> MapSet.new()

    remap =
      Map.new(source.vertices, fn {vertex, _position} ->
        {vertex, if(MapSet.member?(target_vertices, vertex), do: [vertex], else: [])}
      end)

    created_vertices = Map.keys(target.vertices) -- Map.keys(source.vertices)
    created_faces = Map.keys(target.faces) -- Map.keys(source.faces)
    Delta.build!(source, target, remap, created_vertices, created_faces)
  end

  defp entry(state, command_digest, receipt) do
    canonical = %{
      "command_digest" => command_digest,
      "face_ids" => state.selection.face_ids,
      "mesh" => Mesh.canonical_map(state.mesh),
      "receipt" => receipt,
      "selection_revision" => state.selection_revision,
      "source_generation" => state.geometry_generation
    }

    encoded = CanonicalJSON.encode!(canonical)

    %Entry{
      mesh: state.mesh,
      face_ids: state.selection.face_ids,
      source_generation: state.geometry_generation,
      selection_revision: state.selection_revision,
      command_digest: command_digest,
      receipt: receipt,
      digest: digest(encoded),
      bytes: byte_size(encoded)
    }
  end

  defp verify!(entry, state) do
    canonical = %{
      "command_digest" => entry.command_digest,
      "face_ids" => entry.face_ids,
      "mesh" => Mesh.canonical_map(entry.mesh),
      "receipt" => entry.receipt,
      "selection_revision" => entry.selection_revision,
      "source_generation" => entry.source_generation
    }

    observed = canonical |> CanonicalJSON.encode!() |> digest()

    if observed != entry.digest do
      raise Diagnostic.new!(
              "E_WINGS_HISTORY_CORRUPT",
              "history entry digest does not match its logical state",
              %{
                "before_mesh_digest" => Batata.Wings.digest(state.mesh),
                "expected_digest" => entry.digest,
                "observed_digest" => observed,
                "source_generation" => entry.source_generation
              },
              [%{"command" => "discard the corrupt history branch and preserve current state"}]
            )
    end
  end

  defp trim(history) do
    if length(history.past) > history.max_entries or total_bytes(history.past) > history.max_bytes do
      {retained, [evicted | _]} = Enum.split(history.past, -1)

      %{
        history
        | past: retained,
          evicted_generations: history.evicted_generations ++ [evicted.source_generation]
      }
      |> trim()
    else
      recount(history)
    end
  end

  defp recount(history), do: %{history | bytes: total_bytes(history.past ++ history.future)}
  defp total_bytes(entries), do: Enum.reduce(entries, 0, &(&1.bytes + &2))

  defp entry_summary(entry) do
    %{
      "bytes" => entry.bytes,
      "command_digest" => entry.command_digest,
      "digest" => entry.digest,
      "mesh_digest" => Batata.Wings.digest(entry.mesh),
      "selection_digest" => Selection.new!(entry.mesh, entry.face_ids) |> Selection.digest(),
      "source_generation" => entry.source_generation
    }
  end

  defp quota_error!(history, estimate, state) do
    raise Diagnostic.new!(
            "E_WINGS_HISTORY_QUOTA_EXCEEDED",
            "one history entry exceeds the declared byte quota",
            %{
              "estimated_bytes" => estimate,
              "before_mesh_digest" => Batata.Wings.digest(state.mesh),
              "generation" => state.geometry_generation,
              "max_bytes" => history.max_bytes
            },
            [%{"command" => "increase max_bytes to at least #{estimate}"}],
            true
          )
  end

  defp empty!(state, operation) do
    raise Diagnostic.new!(
            "E_WINGS_HISTORY_EMPTY",
            "#{operation} history is empty",
            %{
              "before_mesh_digest" => Batata.Wings.digest(state.mesh),
              "generation" => state.geometry_generation,
              "operation" => operation
            },
            [%{"command" => "commit an edit before requesting #{operation}"}],
            true
          )
  end

  defp digest(value), do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end
