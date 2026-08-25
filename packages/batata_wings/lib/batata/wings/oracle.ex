defmodule Batata.Wings.Oracle do
  @moduledoc "Test-only differential adapter for a pinned local Wings3D checkout."

  alias Batata.Wings.{Diagnostic, Primitive, Provenance, Subdivision, Topology}
  alias Batata.Wings.Topology.Build

  @source_modules ~w(
    ../e3d/e3d_vec ../e3d/e3d_mat ../e3d/e3d_bv
    wings_util wings_we_util wings_we_build wings_we wings_face wings_vertex
    wings_edge wings_va wings_facemat wings_subdiv
  )

  @spec cube_smooth!(Path.t()) :: map()
  def cube_smooth!(wings_path) when is_binary(wings_path) do
    verify_source!(wings_path)

    output =
      Path.join(System.tmp_dir!(), "batata-wings-oracle-#{System.unique_integer([:positive])}")

    File.mkdir_p!(output)

    try do
      compile!(wings_path, output)
      run!(wings_path, output)
    after
      File.rm_rf!(output)
    end
  end

  @spec compare_cube_smooth!(Path.t()) :: map()
  def compare_cube_smooth!(wings_path) when is_binary(wings_path) do
    oracle = cube_smooth!(wings_path)
    mesh = Primitive.cube() |> Subdivision.smooth!()
    stats = mesh |> Build.build!() |> Topology.stats()
    expected_positions = oracle["positions"] |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    observed_positions = mesh.vertices |> Map.values() |> Enum.sort()
    maximum_delta = maximum_position_delta(expected_positions, observed_positions)

    report = %{
      "counts" => Map.take(stats, ["edges", "faces", "vertices"]),
      "maximum_position_delta" => maximum_delta,
      "mesh_digest" => Batata.Wings.digest(mesh),
      "upstream_commit" => Provenance.provenance()["upstream_commit"]
    }

    expected_counts = Map.take(oracle, ["edges", "faces", "vertices"])

    if report["counts"] != expected_counts or maximum_delta > 1.0e-12 do
      raise Diagnostic.new!(
              "E_WINGS_ORACLE_MISMATCH",
              "Batata geometry does not match the pinned Wings3D oracle",
              Map.put(report, "expected_counts", expected_counts)
            )
    end

    Map.put(report, "matches", true)
  end

  defp verify_source!(wings_path) do
    {commit, status} =
      System.cmd("git", ["-C", wings_path, "rev-parse", "HEAD"], stderr_to_stdout: true)

    expected = Provenance.provenance()["upstream_commit"]

    if status != 0 or String.trim(commit) != expected do
      raise Diagnostic.new!(
              "E_WINGS_ORACLE_MISMATCH",
              "oracle checkout does not match the pinned Wings3D source",
              %{
                "expected_commit" => expected,
                "observed_commit" => String.trim(commit),
                "path" => wings_path
              },
              [%{"command" => "git -C #{wings_path} checkout #{expected}"}],
              true
            )
    end
  end

  defp compile!(wings_path, output) do
    tools = Path.join([wings_path, "intl_tools", "tools.erl"])

    case System.cmd("erlc", ["-Werror", "-o", output, tools], stderr_to_stdout: true) do
      {_log, 0} -> :ok
      {log, status} -> oracle_compile_error!(wings_path, log, status)
    end

    sources =
      [
        Path.join([__DIR__, "..", "..", "..", "oracle", "wings_lang.erl"]),
        Path.join([__DIR__, "..", "..", "..", "oracle", "wings_pb.erl"])
      ] ++
        Enum.map(@source_modules, fn
          "../e3d/" <> module -> Path.join([wings_path, "e3d", "#{module}.erl"])
          module -> Path.join([wings_path, "src", "#{module}.erl"])
        end) ++
        [Path.join([__DIR__, "..", "..", "..", "oracle", "batata_wings_oracle.erl"])]

    arguments = [
      "-Werror",
      "-pa",
      output,
      "-o",
      output,
      "-I",
      Path.join(wings_path, "src")
      | sources
    ]

    environment = [{"ERL_LIBS", Path.dirname(wings_path)}]

    case System.cmd("erlc", arguments, env: environment, stderr_to_stdout: true) do
      {_log, 0} ->
        :ok

      {log, status} ->
        oracle_compile_error!(wings_path, log, status)
    end
  end

  defp run!(wings_path, output) do
    expression =
      "io:format(\"~s\", [base64:encode(term_to_binary(batata_wings_oracle:cube_smooth()))]), halt()."

    {encoded, status} =
      System.cmd(
        "erl",
        ["-noshell", "-pa", output, "-eval", expression],
        stderr_to_stdout: false
      )

    if status != 0 do
      raise Diagnostic.new!(
              "E_WINGS_ORACLE_MISMATCH",
              "pinned Wings3D oracle execution failed",
              %{"status" => status, "wings_path" => wings_path}
            )
    end

    encoded |> Base.decode64!() |> :erlang.binary_to_term([:safe])
  end

  defp oracle_compile_error!(wings_path, log, status) do
    raise Diagnostic.new!(
            "E_WINGS_ORACLE_MISMATCH",
            "pinned Wings3D oracle modules did not compile",
            %{"compiler_log" => log, "status" => status, "wings_path" => wings_path},
            [%{"command" => "compile the pinned Wings3D source with Erlang/OTP 27"}],
            true
          )
  end

  defp maximum_position_delta(expected, observed) when length(expected) == length(observed) do
    expected
    |> Enum.zip(observed)
    |> Enum.flat_map(fn {{ex, ey, ez}, {ox, oy, oz}} ->
      [abs(ex - ox), abs(ey - oy), abs(ez - oz)]
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp maximum_position_delta(_expected, _observed), do: :infinity
end
