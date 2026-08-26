defmodule Batata.Wings.Godot do
  @moduledoc """
  The renderer boundary between `Batata.Wings` and Godot `ArrayMesh`.

  Static assets may be materialized from a validated host descriptor. The
  editor path instead compiles the checked-in Wings kernel and keeps its
  fixed-point geometry state rooted in the Godot instance.
  """

  alias Batata.Wings.{CanonicalJSON, Primitive, Subdivision, Topology}

  alias Batata.Wings.Godot.{
    EditorInput,
    EditorPlugin,
    Extension,
    Source,
    StaticExtension,
    Surface
  }

  alias Batata.Wings.Native.Kernel
  alias Batata.Wings.Native.Source, as: NativeSource
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
        StaticExtension,
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

  @doc "Executes the editor fixture through native-owned Wings state in Godot editor mode."
  @spec build_editor_replay!(Path.t(), Beaver.MLIR.Context.t(), keyword()) :: map()
  def build_editor_replay!(output_dir, ctx, options \\ []) do
    source = NativeSource.read!()
    initial = Kernel.cube_state()
    {selected, 0} = Kernel.editor_pointer_button(initial, 3, 0, 0, 5_000, 0, 0, -10)
    {moved, 1} = Kernel.editor_move(selected, 0, 0, 250, 0, 1_024)
    {extruded, 2} = Kernel.editor_extrude(moved, 250, 1, 4_096)
    {individual, 3} = Kernel.editor_extrude_individual(extruded, 250, 2, 4_096)
    {inset, 4} = Kernel.editor_inset(individual, 250, 3, 4_096)
    {beveled, 5} = Kernel.editor_bevel(inset, 100, 50, 4, 4_096)
    {undone, 6} = Kernel.editor_undo(beveled, 5)
    {redone, 7} = Kernel.editor_redo(undone, 6)
    final_surface = surface_expectation(redone)
    initial_selection_indices = elem(Kernel.selected_triangle_indices(selected), 1)
    selection_indices = elem(Kernel.selected_triangle_indices(redone), 1)
    initial_code = Kernel.state_code(initial)
    moved_code = Kernel.state_code(moved)

    godot_options = Keyword.take(options, [:batata, :godot, :zig])

    output = Batata.Godot.build(source, Extension, output_dir, ctx, godot_options)
    plugin = EditorPlugin.write!(output_dir)

    invocations = [
      %{
        method: "state_generation",
        arguments: [],
        expected: 0
      },
      %{
        method: "displayed_mesh_code",
        arguments: [],
        expected: initial_code
      },
      %{
        method: "editor_pointer_button",
        arguments: [3, 0, 0, 5_000, 0, 0, -10],
        expected: 0
      },
      %{
        method: "displayed_mesh_code",
        arguments: [],
        expected: Kernel.state_code(selected)
      },
      %{
        method: "selected_triangle_indices",
        arguments: [],
        expected: initial_selection_indices
      },
      %{
        method: "editor_move",
        arguments: [0, 0, 250, 0, 1_024],
        expected: 1
      },
      %{
        method: "state_generation",
        arguments: [],
        expected: 1
      },
      %{
        method: "displayed_mesh_code",
        arguments: [],
        expected: moved_code
      },
      %{
        method: "editor_layout_code",
        arguments: [],
        expected: 806
      },
      %{
        method: "editor_extrude",
        arguments: [250, 1, 4_096],
        expected: 2
      },
      %{
        method: "editor_layout_code",
        arguments: [],
        expected: 1_210
      },
      %{
        method: "editor_extrude_individual",
        arguments: [250, 2, 4_096],
        expected: 3
      },
      %{
        method: "editor_layout_code",
        arguments: [],
        expected: 1_614
      },
      %{
        method: "editor_inset",
        arguments: [250, 3, 4_096],
        expected: 4
      },
      %{
        method: "editor_layout_code",
        arguments: [],
        expected: 2_018
      },
      %{
        method: "editor_bevel",
        arguments: [100, 50, 4, 4_096],
        expected: 5
      },
      %{
        method: "editor_layout_code",
        arguments: [],
        expected: 2_422
      },
      %{
        method: "displayed_mesh_code",
        arguments: [],
        expected: Kernel.state_code(beveled)
      },
      %{
        method: "selected_triangle_indices",
        arguments: [],
        expected: selection_indices
      },
      %{
        method: "editor_undo",
        arguments: [5],
        expected: 6
      },
      %{
        method: "editor_redo",
        arguments: [6],
        expected: 7
      },
      %{
        method: "mesh",
        arguments: [],
        expected: final_surface
      },
      %{
        method: "editor_move",
        arguments: [0, 0, 250, 0, 1_024],
        expected: -1
      },
      %{
        method: "editor_inset",
        arguments: [500, 7, 4_096],
        expected: -6
      },
      %{
        method: "editor_bevel",
        arguments: [100, 50, 7, 1],
        expected: -3
      },
      %{
        method: "editor_move",
        arguments: [0, 0, 1_000_000, 7, 4_096],
        expected: -4
      },
      %{
        method: "displayed_mesh_code",
        arguments: [],
        expected: Kernel.state_code(redone),
        repeat_same: 1
      }
    ]

    Batata.Godot.editor_smoke_load!(output_dir, Keyword.get(options, :godot), invocations)
    verify_editor_plugin!(output_dir)

    receipt_path = Path.join(output_dir, "editor_replay_receipt.json")

    receipt =
      editor_receipt(
        source,
        output,
        plugin,
        %{
          initial: initial,
          moved: moved,
          extruded: extruded,
          individual: individual,
          inset: inset,
          beveled: beveled,
          undone: undone,
          redone: redone
        },
        selection_indices
      )

    File.write!(receipt_path, CanonicalJSON.encode!(receipt))

    Map.merge(output, %{
      editor_receipt: receipt_path,
      initial_state: initial,
      native_state: redone
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
         source,
         output,
         plugin,
         %{
           initial: initial,
           moved: moved,
           extruded: extruded,
           individual: individual,
           inset: inset,
           beveled: beveled,
           undone: undone,
           redone: redone
         },
         selection_indices
       ) do
    bundle = output.bundle |> File.read!() |> JSON.decode!()

    command = %{
      "event_word" => 3,
      "move" => [0, 0, 250],
      "origin" => [0, 0, 5_000],
      "quota_bytes" => 4_096,
      "ray_direction" => [0, 0, -10]
    }

    %{
      "allocation" => %{
        "estimate_bytes" => 2_192,
        "proof" => "24 bounded vertices + 22 closed quad faces",
        "quota_bytes" => 4_096
      },
      "artifact_bundle_sha256" => digest_file(output.bundle),
      "binding_plan_sha256" => bundle["binding_plan_sha256"],
      "compiler" => "batata_wings_godot",
      "differential" => %{
        "after_state_code" => Kernel.state_code(redone),
        "before_state_code" => Kernel.state_code(initial),
        "matched" => true
      },
      "event_schema" => EditorInput.schema(),
      "event_schema_sha256" => EditorInput.schema_digest(),
      "functions" => [
        "editor_pointer_button/8",
        "editor_move/6",
        "editor_extrude/4",
        "editor_extrude_individual/4",
        "editor_inset/4",
        "editor_bevel/5",
        "editor_undo/2",
        "editor_redo/2",
        "mesh/1",
        "state_generation/1",
        "editor_layout_code/1",
        "displayed_mesh_code/1",
        "selected_triangle_indices/1",
        "topology_code_for_state/1"
      ],
      "godot_api_sha256" => bundle["godot_api_sha256"],
      "godot_api_version" => bundle["godot_api_version"],
      "native_source" => NativeSource.identity(),
      "operation" => "native_pick_move_region_individual_extrude_inset_bevel_history",
      "editor_plugin" => %{
        "config_sha256" => plugin.config_sha256,
        "script_sha256" => plugin.script_sha256
      },
      "portable_state" => %{
        "ownership" => "godot_instance",
        "replacement_policy" => "deep_export_then_atomic_replace"
      },
      "provenance" => Batata.Wings.provenance(),
      "replay_command" =>
        "mix test test/build_test.exs --only editor_replay --seed 0 --max-cases 1",
      "runtime_command_sha256" => command |> CanonicalJSON.encode!() |> digest(),
      "schema_version" => 1,
      "selected_triangle_indices" => selection_indices,
      "source_sha256" => digest(source),
      "steps" => [
        %{"after_generation" => 0, "code" => 0, "operation" => "pick"},
        %{"after_generation" => 1, "code" => 1, "operation" => "move"},
        %{"after_generation" => 2, "code" => 2, "operation" => "region_extrude"},
        %{"after_generation" => 3, "code" => 3, "operation" => "individual_extrude"},
        %{"after_generation" => 4, "code" => 4, "operation" => "inset"},
        %{"after_generation" => 5, "code" => 5, "operation" => "bevel"},
        %{"after_generation" => 6, "code" => 6, "operation" => "undo"},
        %{"after_generation" => 7, "code" => 7, "operation" => "redo"},
        %{"after_generation" => 7, "code" => -1, "operation" => "stale_move"},
        %{"after_generation" => 7, "code" => -6, "operation" => "invalid_inset"},
        %{"after_generation" => 7, "code" => -3, "operation" => "quota_bevel"},
        %{"after_generation" => 7, "code" => -4, "operation" => "overflow_move"}
      ],
      "diagnostics" => diagnostic_receipt(),
      "identity_delta" => [
        identity_delta("region_extrude", 8, 11, 6, 9),
        identity_delta("individual_extrude", 12, 15, 10, 13),
        identity_delta("inset", 16, 19, 14, 17),
        identity_delta("bevel", 20, 23, 18, 21)
      ],
      "topology" => %{
        "after" => topology_receipt(redone),
        "before" => topology_receipt(initial)
      },
      "history" => %{
        "beveled_state_code" => Kernel.state_code(beveled),
        "extruded_state_code" => Kernel.state_code(extruded),
        "individual_extruded_state_code" => Kernel.state_code(individual),
        "inset_state_code" => Kernel.state_code(inset),
        "moved_state_code" => Kernel.state_code(moved),
        "redo_state_code" => Kernel.state_code(redone),
        "undo_state_code" => Kernel.state_code(undone)
      },
      "versions" => %{
        "batata" => application_version(:batata),
        "batata_godot" => application_version(:batata_godot),
        "batata_wings" => application_version(:batata_wings),
        "elixir" => System.version(),
        "otp" => System.otp_release()
      }
    }
  end

  defp surface_expectation(state) do
    {_same_state, {vertices, indices, scale}} = Kernel.mesh(state)

    vertices =
      Enum.map(vertices, fn {x, y, z} ->
        [x / scale, y / scale, z / scale]
      end)

    %{array_mesh: %{vertices: vertices, indices: indices}}
  end

  defp topology_receipt(state) do
    {closed, vertices, edges, faces, euler} = Kernel.topology_stats(state)

    %{
      "closed" => closed,
      "edges" => edges,
      "euler_characteristic" => euler,
      "faces" => faces,
      "vertices" => vertices
    }
  end

  defp identity_delta(operation, vertex_first, vertex_last, face_first, face_last) do
    %{
      "created_face_ids" => Enum.to_list(face_first..face_last),
      "created_vertex_ids" => Enum.to_list(vertex_first..vertex_last),
      "operation" => operation,
      "preserved_existing_ids" => true
    }
  end

  defp diagnostic_receipt do
    %{
      "-1" => diagnostic("E_WINGS_NATIVE_GENERATION_STALE", "retry with observed generation"),
      "-2" => diagnostic("E_WINGS_NATIVE_SELECTION_INVALID", "select one canonical face"),
      "-3" => diagnostic("E_WINGS_NATIVE_MEMORY_QUOTA_EXCEEDED", "raise quota_bytes"),
      "-4" =>
        diagnostic("E_WINGS_NATIVE_FIXED_POINT_OVERFLOW", "reduce fixed-point displacement"),
      "-5" =>
        diagnostic("E_WINGS_NATIVE_HISTORY_UNAVAILABLE", "stop undo or redo at history boundary"),
      "-6" => diagnostic("E_WINGS_NATIVE_LAYOUT_UNSUPPORTED", "use bounded operation parameters"),
      "-7" =>
        diagnostic("E_WINGS_NATIVE_TOPOLOGY_INVALID", "repair the selected closed quad region")
    }
  end

  defp diagnostic(code, next_action) do
    %{
      "code" => code,
      "recoverable" => true,
      "state_policy" => "preserve_before_state",
      "next_action" => next_action
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
