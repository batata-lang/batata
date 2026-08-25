defmodule Batata.Wings.Godot do
  @moduledoc """
  The renderer boundary between `Batata.Wings` and Godot `ArrayMesh`.

  Geometry and topology remain in `batata_wings`. This package converts a
  validated mesh into a fixed-point, triangle-only surface descriptor, embeds
  that descriptor in Batata source, and delegates the native ABI to
  `batata_godot`.
  """

  alias Batata.Wings.{CanonicalJSON, EditorState, Primitive, Subdivision, Topology}
  alias Batata.Wings.Godot.{EditorInput, EditorPlugin, EditorSession, Extension, Source, Surface}
  alias Batata.Wings.Topology.Build, as: TopologyBuild

  @scale 36

  @doc "Builds the oracle-validated, once-subdivided cube as a real Godot ArrayMesh."
  @spec build_cube!(Path.t(), Beaver.MLIR.Context.t(), keyword()) :: map()
  def build_cube!(output_dir, ctx, options \\ []) do
    mesh = Primitive.cube() |> Subdivision.smooth!()
    topology = mesh |> TopologyBuild.build!() |> Topology.validate!()
    surface = Surface.from_mesh!(mesh, scale: @scale)
    source = Source.for_surface(surface, Batata.Wings.digest(mesh))
    godot_options = Keyword.take(options, [:batata, :godot, :zig])

    output =
      Batata.Godot.build(
        source,
        Extension,
        output_dir,
        ctx,
        godot_options ++ [smoke: [Surface.smoke_invocation(surface)]]
      )

    receipt_path = Path.join(output_dir, "mesh_receipt.json")
    receipt = receipt(mesh, topology, surface, source, output)
    File.write!(receipt_path, CanonicalJSON.encode!(receipt))

    Map.merge(output, %{
      mesh_digest: receipt["mesh_digest"],
      mesh_receipt: receipt_path,
      surface: surface
    })
  end

  @doc "Replays the fixed transactional editor scene and verifies its final surface in Godot editor mode."
  @spec build_editor_replay!(Path.t(), Beaver.MLIR.Context.t(), keyword()) :: map()
  def build_editor_replay!(output_dir, ctx, options \\ []) do
    replay = Primitive.cube() |> EditorState.new!(max_entries: 8) |> EditorSession.replay!()
    surface = Surface.from_mesh!(replay.final.mesh, scale: 1_000_000, tolerance: 1.0e-6)
    mesh_digest = Batata.Wings.digest(replay.final.mesh)
    state_digest = EditorState.digest(replay.final)
    state_snapshot = replay.final |> EditorState.canonical_map() |> CanonicalJSON.encode!()
    selection_indices = Surface.selection_indices(surface, replay.final.selection)

    source =
      Source.for_surface(surface, mesh_digest, %{
        generation: replay.final.geometry_generation,
        input_schema_digest: EditorInput.schema_digest(),
        selection_indices: selection_indices,
        state_snapshot: state_snapshot,
        state_digest: state_digest
      })

    godot_options = Keyword.take(options, [:batata, :godot, :zig])

    output = Batata.Godot.build(source, Extension, output_dir, ctx, godot_options)
    plugin = EditorPlugin.write!(output_dir)

    invocations = [
      %{
        method: "editor_pointer_button",
        arguments: [[640.0, 360.0], 1, true, 0, [0.0, 0.0, 5.0], [0.0, 0.0, -1.0], 0],
        expected: 0
      },
      %{
        method: "editor_key_chord",
        arguments: [90, 3, true, replay.final.geometry_generation],
        expected: replay.final.geometry_generation
      },
      Surface.smoke_invocation(surface),
      %{
        method: "state_generation",
        arguments: [],
        expected: replay.final.geometry_generation
      },
      %{method: "displayed_mesh_digest", arguments: [], expected: state_digest},
      %{method: "selected_triangle_indices", arguments: [], expected: selection_indices},
      %{method: "input_schema_digest", arguments: [], expected: EditorInput.schema_digest()},
      %{
        method: "editor_state_snapshot",
        arguments: [],
        expected: state_snapshot,
        repeat_same: 2
      }
    ]

    Batata.Godot.editor_smoke_load!(output_dir, Keyword.get(options, :godot), invocations)
    verify_editor_plugin!(output_dir)

    receipt_path = Path.join(output_dir, "editor_replay_receipt.json")

    receipt =
      editor_receipt(replay, surface, source, output, plugin, state_digest, selection_indices)

    File.write!(receipt_path, CanonicalJSON.encode!(receipt))

    Map.merge(output, %{
      editor_receipt: receipt_path,
      mesh_digest: mesh_digest,
      replay: replay,
      surface: surface
    })
  end

  defp receipt(mesh, topology, surface, source, output) do
    bundle = output.bundle |> File.read!() |> JSON.decode!()

    %{
      "artifact_bundle_sha256" => digest_file(output.bundle),
      "binding_plan_sha256" => bundle["binding_plan_sha256"],
      "compiler" => "batata_wings_godot",
      "godot_api_version" => bundle["godot_api_version"],
      "mesh_digest" => Batata.Wings.digest(mesh),
      "operation" => "cube_catmull_clark_1_array_mesh",
      "provenance" => Batata.Wings.provenance(),
      "replay_command" => "mix test test/build_test.exs --seed 0 --max-cases 1",
      "schema_version" => 1,
      "source_sha256" => digest(source),
      "surface" => Surface.receipt(surface),
      "topology" => Topology.stats(topology),
      "versions" => %{
        "batata" => application_version(:batata),
        "batata_godot" => application_version(:batata_godot),
        "batata_wings" => application_version(:batata_wings),
        "elixir" => System.version(),
        "otp" => System.otp_release()
      }
    }
  end

  defp editor_receipt(
         replay,
         surface,
         source,
         output,
         plugin,
         state_digest,
         selection_indices
       ) do
    bundle = output.bundle |> File.read!() |> JSON.decode!()
    state_snapshot = replay.final |> EditorState.canonical_map() |> CanonicalJSON.encode!()

    %{
      "artifact_bundle_sha256" => digest_file(output.bundle),
      "binding_plan_sha256" => bundle["binding_plan_sha256"],
      "compiler" => "batata_wings_godot",
      "displayed_mesh_digest" => replay.final_digest,
      "event_schema" => EditorInput.schema(),
      "event_schema_sha256" => EditorInput.schema_digest(),
      "final_state_digest" => state_digest,
      "godot_api_sha256" => bundle["godot_api_sha256"],
      "godot_api_version" => bundle["godot_api_version"],
      "history" => %{
        "bytes" => replay.final.history.bytes,
        "max_bytes" => replay.final.history.max_bytes,
        "max_entries" => replay.final.history.max_entries
      },
      "operation" => "editor_select_move_extrude_inset_bevel_undo_redo",
      "editor_plugin" => %{
        "config_sha256" => plugin.config_sha256,
        "script_sha256" => plugin.script_sha256
      },
      "portable_state" => %{
        "bytes" => byte_size(state_snapshot),
        "replacement_policy" => "replace",
        "sha256" => digest(state_snapshot)
      },
      "provenance" => Batata.Wings.provenance(),
      "replay_command" =>
        "mix test test/build_test.exs --only editor_replay --seed 0 --max-cases 1",
      "schema_version" => 1,
      "selected_triangle_indices" => selection_indices,
      "source_sha256" => digest(source),
      "steps" => replay.steps,
      "surface" => Surface.receipt(surface),
      "undo_mesh_digest" => replay.undo_digest,
      "versions" => %{
        "batata" => application_version(:batata),
        "batata_godot" => application_version(:batata_godot),
        "batata_wings" => application_version(:batata_wings),
        "elixir" => System.version(),
        "otp" => System.otp_release()
      }
    }
  end

  defp digest_file(path), do: path |> File.read!() |> digest()

  defp verify_editor_plugin!(output_dir) do
    marker = Path.join(output_dir, ".batata/editor-plugin-ready")

    unless File.read(marker) == {:ok, "ready"} do
      raise Batata.Godot.Diagnostic,
        code: "E_GODOT_EDITOR_STATE_UNAVAILABLE",
        message: "Godot editor did not execute the closed Wings editor plugin",
        context: %{marker: marker},
        actions: [%{command: "inspect the generated editor plugin and editor-mode smoke output"}]
    end
  end

  defp digest(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp application_version(application) do
    application |> Application.spec(:vsn) |> to_string()
  end
end
