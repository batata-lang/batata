defmodule Batata.Wings.Editor do
  @moduledoc "Executes fail-closed editor commands as atomic state transitions."

  alias Batata.Wings.{
    Diagnostic,
    EditCommand,
    EditorState,
    EditResult,
    History,
    IdentityDelta,
    Selection,
    Topology
  }

  alias Batata.Wings.Operation.{Bevel, Extrude, Inset, Move}
  alias Batata.Wings.Topology.Build

  @spec execute!(EditorState.t(), EditCommand.t()) :: {EditorState.t(), EditResult.t()}
  def execute!(%EditorState{} = state, %EditCommand{} = command) do
    validate_preconditions!(state, command)

    case command.operation do
      :select -> select(state, command)
      :move -> move(state, command)
      :extrude -> extrude(state, command)
      :inset -> geometry_operation(state, command, Inset)
      :bevel -> geometry_operation(state, command, Bevel)
      :undo -> history_operation(state, command, :undo)
      :redo -> history_operation(state, command, :redo)
      operation -> unsupported!(state, command, operation)
    end
  end

  defp select(state, command) do
    operation = selection_operation!(state, command.arguments["mode"])
    face_ids = Map.get(command.arguments, "face_ids", [])

    selection =
      Selection.update!(
        state.selection,
        state.mesh,
        state.geometry_generation,
        operation,
        face_ids
      )

    updated = %{state | selection: selection, selection_revision: selection.revision}
    changed = selection != state.selection
    delta = identity_delta(state.mesh)
    finish(state, updated, command, delta, changed)
  end

  defp move(state, command) do
    face_ids = Map.get(command.arguments, "face_ids", state.selection.face_ids)
    Selection.new!(state.mesh, face_ids, state.geometry_generation)

    {mesh, delta, changed} =
      Move.apply!(state.mesh, face_ids, command.arguments, command.quota_bytes)

    updated =
      if changed do
        generation = state.geometry_generation + 1
        selection = Selection.new!(mesh, face_ids, generation, state.selection_revision)

        %{
          state
          | mesh: mesh,
            selection: selection,
            geometry_generation: generation
        }
      else
        state
      end

    finish(state, updated, command, delta, changed)
  end

  defp extrude(state, command) do
    face_ids = Map.get(command.arguments, "face_ids", state.selection.face_ids)
    Selection.new!(state.mesh, face_ids, state.geometry_generation)

    {mesh, delta, changed} =
      Extrude.apply!(state.mesh, face_ids, command.arguments, command.quota_bytes)

    commit_geometry(state, command, mesh, face_ids, delta, changed)
  end

  defp geometry_operation(state, command, module) do
    face_ids = Map.get(command.arguments, "face_ids", state.selection.face_ids)
    Selection.new!(state.mesh, face_ids, state.geometry_generation)

    {mesh, delta, changed} =
      module.apply!(state.mesh, face_ids, command.arguments, command.quota_bytes)

    commit_geometry(state, command, mesh, face_ids, delta, changed)
  end

  defp history_operation(state, command, operation) do
    {restored, delta} =
      case operation do
        :undo -> History.undo!(state, EditCommand.digest(command))
        :redo -> History.redo!(state, EditCommand.digest(command))
      end

    finish(state, restored, command, delta, true, false)
  end

  defp commit_geometry(state, command, mesh, face_ids, delta, changed) do
    updated =
      if changed do
        generation = state.geometry_generation + 1
        selection = Selection.new!(mesh, face_ids, generation, state.selection_revision)

        %{
          state
          | mesh: mesh,
            selection: selection,
            geometry_generation: generation
        }
      else
        state
      end

    finish(state, updated, command, delta, changed)
  end

  defp finish(previous, candidate, command, delta, changed, record_history \\ true) do
    receipt = receipt(previous, candidate, command, delta, changed)

    history =
      if record_history and changed and command.operation != :select do
        History.push!(candidate.history, previous, EditCommand.digest(command), receipt)
      else
        candidate.history
      end

    committed = %{candidate | history: history, last_receipt: receipt}
    {committed, EditResult.new!(committed, delta, receipt, changed)}
  end

  defp receipt(previous, candidate, command, delta, changed) do
    topology = Build.build!(candidate.mesh)

    %{
      "after_mesh_digest" => Batata.Wings.digest(candidate.mesh),
      "after_state_digest" => EditorState.digest(candidate),
      "before_mesh_digest" => Batata.Wings.digest(previous.mesh),
      "before_state_digest" => EditorState.digest(previous),
      "changed" => changed,
      "command_digest" => EditCommand.digest(command),
      "generation" => candidate.geometry_generation,
      "identity_delta" => IdentityDelta.canonical_map(delta),
      "operation" => Atom.to_string(command.operation),
      "replay_command" => "mix test test/edit_move_test.exs --seed 0 --max-cases 1",
      "selection_digest" => Selection.digest(candidate.selection),
      "topology" => Topology.stats(topology)
    }
  end

  defp identity_delta(mesh) do
    topology = Build.build!(mesh)
    IdentityDelta.identity(mesh, Map.keys(topology.edges))
  end

  defp validate_preconditions!(state, command) do
    observed_digest = Batata.Wings.digest(state.mesh)

    cond do
      command.expected_generation != state.geometry_generation ->
        stale!(
          "E_WINGS_EDIT_GENERATION_STALE",
          "edit command targets a stale geometry generation",
          state,
          command,
          observed_digest
        )

      command.source_mesh_digest != observed_digest ->
        stale!(
          "E_WINGS_EDIT_PRECONDITION_FAILED",
          "edit command source digest does not match editor state",
          state,
          command,
          observed_digest
        )

      true ->
        Selection.validate!(state.selection, state.mesh, state.geometry_generation)
    end
  end

  defp stale!(code, message, state, command, observed_digest) do
    raise Diagnostic.new!(
            code,
            message,
            %{
              "expected_generation" => command.expected_generation,
              "expected_mesh_digest" => command.source_mesh_digest,
              "observed_generation" => state.geometry_generation,
              "observed_mesh_digest" => observed_digest,
              "operation" => Atom.to_string(command.operation),
              "selection_digest" => Selection.digest(state.selection)
            },
            [%{"command" => "rebase the edit command on the current editor state"}],
            true
          )
  end

  defp selection_operation!(_state, "replace"), do: :replace
  defp selection_operation!(_state, "add"), do: :add
  defp selection_operation!(_state, "remove"), do: :remove
  defp selection_operation!(_state, "toggle"), do: :toggle
  defp selection_operation!(_state, "clear"), do: :clear

  defp selection_operation!(state, mode) do
    raise Diagnostic.new!(
            "E_WINGS_SELECTION_INVALID",
            "unknown selection mode",
            %{
              "before_mesh_digest" => Batata.Wings.digest(state.mesh),
              "mode" => inspect(mode)
            }
          )
  end

  defp unsupported!(state, command, operation) do
    raise Diagnostic.new!(
            "E_WINGS_EDIT_PRECONDITION_FAILED",
            "edit operation is not implemented by this transaction layer",
            %{
              "before_mesh_digest" => Batata.Wings.digest(state.mesh),
              "command_digest" => EditCommand.digest(command),
              "operation" => Atom.to_string(operation)
            }
          )
  end
end
