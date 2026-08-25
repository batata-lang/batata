defmodule Batata.Wings.Godot do
  @moduledoc """
  The renderer boundary between `Batata.Wings` and Godot `ArrayMesh`.

  Geometry and topology remain in `batata_wings`. This package converts a
  validated mesh into a fixed-point, triangle-only surface descriptor, embeds
  that descriptor in Batata source, and delegates the native ABI to
  `batata_godot`.
  """

  alias Batata.Wings.CanonicalJSON
  alias Batata.Wings.Godot.{Extension, Source, Surface}
  alias Batata.Wings.{Primitive, Subdivision, Topology}
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

  defp digest_file(path), do: path |> File.read!() |> digest()

  defp digest(value) do
    value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp application_version(application) do
    application |> Application.spec(:vsn) |> to_string()
  end
end
