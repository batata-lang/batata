defmodule Batata.Wings.Godot.EditorSession do
  @moduledoc "Deterministic projection of closed Godot input onto Wings edit transactions."

  alias Batata.Godot.Diagnostic
  alias Batata.Wings.{EditCommand, Editor, EditorState, Geometry, Picking, Selection, Topology}
  alias Batata.Wings.Godot.{EditorInput, Surface}
  alias Batata.Wings.Topology.Build

  @scale 1_000_000

  @type replay :: %{
          initial: EditorState.t(),
          final: EditorState.t(),
          steps: [map()],
          undo_digest: binary(),
          final_digest: binary()
        }

  @doc "Routes one canonical editor event, rejecting stale or unknown input without mutation."
  @spec handle!(EditorState.t(), map()) :: {EditorState.t(), Batata.Wings.EditResult.t() | :miss}
  def handle!(%EditorState{} = state, raw_event) do
    event = EditorInput.normalize!(raw_event)
    validate_generation!(state, event)

    case event do
      %{"kind" => "pointer_button", "pressed" => true, "button" => "primary"} ->
        select_from_ray(state, event)

      %{"kind" => "pointer_button"} ->
        {state, :miss}

      %{"kind" => "key_chord", "pressed" => true, "key" => key, "modifiers" => modifiers}
      when key in ["z", "y"] ->
        history_from_chord(state, event, key, modifiers)

      %{"kind" => "key_chord"} ->
        {state, :miss}
    end
  end

  @doc "Runs the fixed select/edit/undo/redo scene used by the Godot editor receipt."
  @spec replay!(EditorState.t()) :: replay()
  def replay!(%EditorState{} = initial) do
    {selected, selection_result} = handle!(initial, pointer_event(initial))

    operations = [
      {:move, %{"normal_distance" => 0.25}},
      {:extrude, %{"direction" => "normal", "distance" => 0.5, "mode" => "region"}},
      {:inset, %{"ratio" => 0.2}},
      {:bevel, %{"segments" => 1, "width" => 0.05}}
    ]

    {edited, edit_steps} =
      Enum.reduce(operations, {selected, []}, fn {operation, arguments}, {state, steps} ->
        {next, result} = execute(state, operation, arguments)
        {next, steps ++ [step(state, next, result, nil)]}
      end)

    {undone, undo_steps} = replay_history(edited, :undo, 4)

    unless Batata.Wings.digest(undone.mesh) == Batata.Wings.digest(initial.mesh) do
      state_error!("undo replay did not restore the original mesh", initial, undone)
    end

    {redone, redo_steps} = replay_history(undone, :redo, 4)

    unless Batata.Wings.digest(redone.mesh) == Batata.Wings.digest(edited.mesh) do
      state_error!("redo replay did not restore the final mesh", edited, redone)
    end

    %{
      initial: initial,
      final: redone,
      steps:
        [step(initial, selected, selection_result, pointer_event(initial))] ++
          edit_steps ++ undo_steps ++ redo_steps,
      undo_digest: Batata.Wings.digest(undone.mesh),
      final_digest: Batata.Wings.digest(redone.mesh)
    }
  end

  defp select_from_ray(state, event) do
    %{"origin" => origin, "direction" => direction} = event["camera_ray"]
    origin = List.to_tuple(origin)
    direction = List.to_tuple(direction)

    case Picking.pick_face(state.mesh, origin, direction) do
      :miss ->
        {state, :miss}

      {:hit, hit} ->
        mode = selection_mode(event["modifiers"])
        execute(state, :select, %{"face_ids" => [hit.face_id], "mode" => mode})
    end
  end

  defp history_from_chord(state, event, "z", modifiers) do
    operation = if "shift" in modifiers, do: :redo, else: :undo
    execute(state, operation, %{"event_digest" => EditorInput.digest(event)})
  end

  defp history_from_chord(state, event, "y", modifiers) do
    if Enum.any?(modifiers, &(&1 in ["command", "control"])) do
      execute(state, :redo, %{"event_digest" => EditorInput.digest(event)})
    else
      {state, :miss}
    end
  end

  defp selection_mode(modifiers) do
    cond do
      Enum.any?(modifiers, &(&1 in ["command", "control"])) -> "toggle"
      "shift" in modifiers -> "add"
      true -> "replace"
    end
  end

  defp replay_history(state, operation, count) do
    Enum.reduce(1..count, {state, []}, fn _index, {current, steps} ->
      event = history_event(current, operation)
      {next, result} = handle!(current, event)
      {next, steps ++ [step(current, next, result, event)]}
    end)
  end

  defp execute(state, operation, arguments) do
    command =
      EditCommand.new!(
        operation,
        arguments,
        Batata.Wings.digest(state.mesh),
        state.geometry_generation
      )

    Editor.execute!(state, command)
  end

  defp step(before, after_state, result, event) do
    surface = Surface.from_mesh!(after_state.mesh, scale: @scale, tolerance: 1.0e-6)

    %{
      "after_mesh_digest" => Batata.Wings.digest(after_state.mesh),
      "before_mesh_digest" => Batata.Wings.digest(before.mesh),
      "command" => if(result == :miss, do: nil, else: result.receipt["operation"]),
      "event_digest" => if(event, do: EditorInput.digest(event), else: nil),
      "generation" => after_state.geometry_generation,
      "history_bytes" => after_state.history.bytes,
      "memory_estimate_bytes" => Geometry.estimate_bytes(after_state.mesh),
      "selection" => Selection.canonical_map(after_state.selection),
      "surface" => Surface.receipt(surface),
      "topology" => after_state.mesh |> Build.build!() |> Topology.stats()
    }
  end

  defp pointer_event(state) do
    %{
      "button" => "primary",
      "camera_ray" => %{"direction" => [0.0, 0.0, -1.0], "origin" => [0.0, 0.0, 5.0]},
      "expected_generation" => state.geometry_generation,
      "kind" => "pointer_button",
      "modifiers" => [],
      "position" => [640.0, 360.0],
      "pressed" => true
    }
  end

  defp history_event(state, :undo) do
    %{
      "expected_generation" => state.geometry_generation,
      "key" => "z",
      "kind" => "key_chord",
      "modifiers" => ["command"],
      "pressed" => true
    }
  end

  defp history_event(state, :redo) do
    %{
      "expected_generation" => state.geometry_generation,
      "key" => "z",
      "kind" => "key_chord",
      "modifiers" => ["command", "shift"],
      "pressed" => true
    }
  end

  defp validate_generation!(state, event) do
    expected = event["expected_generation"]

    if expected != state.geometry_generation do
      raise Diagnostic,
        code: "E_GODOT_EDITOR_STATE_STALE",
        message: "editor event targets a stale geometry generation",
        context: %{
          "before_mesh_digest" => Batata.Wings.digest(state.mesh),
          "expected_generation" => expected,
          "observed_generation" => state.geometry_generation,
          "selection_digest" => Selection.digest(state.selection)
        },
        actions: [%{command: "rebase the event on the current editor state"}]
    end
  end

  defp state_error!(message, expected, observed) do
    raise Diagnostic,
      code: "E_GODOT_EDITOR_STATE_UNAVAILABLE",
      message: message,
      context: %{
        "expected_mesh_digest" => Batata.Wings.digest(expected.mesh),
        "observed_mesh_digest" => Batata.Wings.digest(observed.mesh)
      },
      actions: [%{command: "discard the replay candidate and preserve the displayed mesh"}]
  end
end
