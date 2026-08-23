defmodule Batata.Godot.Build do
  @moduledoc """
  Builds the first loadable Batata GDExtension artifact boundary.

  The current target is intentionally narrow: Godot 4.6.2, macOS arm64 and
  Zig 0.16. It links the Batata object and term runtime into a dynamic library,
  exports the configured GDExtension entry point, and can replay a real Godot
  headless load smoke. It does not register the declared class yet.
  """

  alias Batata.Godot.{BindingPlan, Diagnostic, Resource}

  @godot_api_version "4.6.2"
  @godot_api_sha256 "34d7058f31af186d36b84567e70a9f9543da0d74f25cfe5266d4fe2d27e090f0"
  @initialization_levels %{core: 0, servers: 1, scene: 2, editor: 3}
  @target "aarch64-apple-darwin"
  @option_keys [:batata, :godot, :smoke, :zig]

  @type output :: %{
          library: Path.t(),
          gdextension: Path.t(),
          binding_plan: Path.t(),
          bundle: Path.t(),
          artifact_index: Path.t(),
          manifest: Path.t(),
          native: map()
        }

  @doc "Builds a loadable, empty GDExtension around a Batata compilation unit."
  @spec build(
          String.t(),
          module() | BindingPlan.t(),
          Path.t(),
          Beaver.MLIR.Context.t(),
          keyword()
        ) ::
          output()
  def build(source, extension, output_dir, ctx, opts \\ [])
      when is_binary(source) and is_binary(output_dir) do
    validate_options!(opts)
    validate_platform!()

    plan = normalize_plan(extension)
    validate_api_version!(plan)
    {zig, zig_version} = resolve_zig!(opts[:zig])

    native_dir = Path.join(output_dir, ".batata")
    bin_dir = Path.join(output_dir, "bin")
    File.mkdir_p!(bin_dir)

    binding_plan_path = Path.join(output_dir, "binding_plan.json")
    library_name = "lib#{plan.extension}.macos.debug.arm64.dylib"
    library_path = Path.join(bin_dir, library_name)
    gdextension_path = Path.join(bin_dir, "#{plan.extension}.gdextension")

    File.write!(binding_plan_path, BindingPlan.canonical_json(plan))

    native = Batata.build(source, native_dir, ctx, Keyword.get(opts, :batata, []))
    verify_method_symbols!(native.archive, plan)
    link!(zig, plan, native, native_dir, library_path)
    verify_library_symbols!(library_path, plan)
    File.write!(gdextension_path, Resource.gdextension_source(plan, library_name))

    metadata =
      write_metadata!(output_dir, plan, zig_version,
        binding_plan: binding_plan_path,
        gdextension: gdextension_path,
        library: library_path,
        native: native
      )

    if Keyword.get(opts, :smoke, false) do
      smoke_load!(output_dir, Keyword.get(opts, :godot))
    end

    Map.merge(metadata, %{
      binding_plan: binding_plan_path,
      gdextension: gdextension_path,
      library: library_path,
      native: native
    })
  end

  @doc "Loads and unloads a generated extension with the pinned Godot headless executable."
  @spec smoke_load!(Path.t(), Path.t() | nil) :: :ok
  def smoke_load!(output_dir, godot \\ nil) when is_binary(output_dir) do
    godot = resolve_godot!(godot)
    project_path = Path.join(output_dir, "project.godot")
    extension_list_dir = Path.join(output_dir, ".godot")
    extension_list_path = Path.join(extension_list_dir, "extension_list.cfg")

    File.mkdir_p!(extension_list_dir)

    File.write!(project_path, """
    ; Generated Batata Godot load-smoke project.
    config_version=5

    [application]
    config/name="Batata Godot Load Smoke"

    [rendering]
    renderer/rendering_method="gl_compatibility"
    """)

    extension =
      output_dir
      |> Path.join("bin/*.gdextension")
      |> Path.wildcard()
      |> case do
        [path] ->
          "res://bin/#{Path.basename(path)}\n"

        paths ->
          diagnostic!(
            "E_GODOT_EXTENSION_RESOURCE_MISSING",
            "load smoke requires exactly one .gdextension resource",
            %{count: length(paths)}
          )
      end

    File.write!(extension_list_path, extension)

    case System.cmd(godot, ["--headless", "--editor", "--path", output_dir, "--quit"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if load_error?(output) do
          diagnostic!(
            "E_GODOT_LOAD_FAILED",
            "Godot reported a GDExtension loading error",
            %{output: output},
            [%{command: "inspect the generated .gdextension resource and dynamic library"}]
          )
        end

        :ok

      {output, status} ->
        diagnostic!(
          "E_GODOT_LOAD_FAILED",
          "Godot headless load smoke exited unsuccessfully",
          %{exit_status: status, output: output}
        )
    end
  end

  defp normalize_plan(%BindingPlan{} = plan), do: plan
  defp normalize_plan(module) when is_atom(module), do: Batata.Godot.binding_plan(module)

  defp normalize_plan(value) do
    diagnostic!(
      "E_GODOT_BINDING_PLAN_MISSING",
      "build requires an extension module or binding plan",
      %{value: inspect(value)}
    )
  end

  defp validate_options!(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- @option_keys do
        [] ->
          :ok

        unknown ->
          diagnostic!("E_GODOT_OPTION_UNKNOWN", "build contains unknown options", %{
            options: unknown
          })
      end
    else
      diagnostic!("E_GODOT_OPTION_INVALID", "build options must be a keyword list", %{})
    end

    unless Keyword.keyword?(Keyword.get(opts, :batata, [])) do
      diagnostic!(
        "E_GODOT_OPTION_INVALID",
        ":batata must contain Batata.build/4 keyword options",
        %{field: :batata}
      )
    end
  end

  defp validate_platform! do
    architecture = :erlang.system_info(:system_architecture) |> List.to_string()

    unless match?({:unix, :darwin}, :os.type()) and String.starts_with?(architecture, "aarch64-") do
      diagnostic!(
        "E_GODOT_PLATFORM_UNSUPPORTED",
        "the first GDExtension build target is macOS arm64 only",
        %{host: architecture, supported: [@target]},
        [%{command: "build on an arm64 macOS host"}]
      )
    end
  end

  defp validate_api_version!(%BindingPlan{} = plan) do
    requested = version_tuple(plan.compatibility_minimum)
    supported = version_tuple(@godot_api_version)

    unless elem(requested, 0) == 4 and requested <= supported do
      diagnostic!(
        "E_GODOT_API_VERSION_MISMATCH",
        "binding plan compatibility exceeds the pinned Godot API",
        %{compatibility_minimum: plan.compatibility_minimum, godot_api: @godot_api_version},
        [%{command: "set compatibility_minimum to 4.6 or earlier"}]
      )
    end
  end

  defp version_tuple(version) do
    case version |> String.split(".") |> Enum.map(&String.to_integer/1) do
      [major, minor] -> {major, minor, 0}
      [major, minor, patch] -> {major, minor, patch}
    end
  end

  defp resolve_zig!(nil) do
    case System.find_executable("zig") do
      nil -> diagnostic!("E_GODOT_ZIG_MISSING", "Zig is required to link the GDExtension", %{})
      zig -> resolve_zig!(zig)
    end
  end

  defp resolve_zig!(zig) when is_binary(zig) do
    case System.cmd(zig, ["version"], stderr_to_stdout: true) do
      {output, 0} ->
        version = String.trim(output)

        if String.starts_with?(version, "0.16.") do
          {zig, version}
        else
          diagnostic!(
            "E_GODOT_ZIG_VERSION_MISMATCH",
            "the first GDExtension target requires Zig 0.16",
            %{actual: version, required: "0.16.x"}
          )
        end

      {output, status} ->
        diagnostic!("E_GODOT_ZIG_MISSING", "Zig version probe failed", %{
          exit_status: status,
          output: output
        })
    end
  rescue
    error in ErlangError ->
      diagnostic!("E_GODOT_ZIG_MISSING", "Zig executable could not be started", %{
        reason: Exception.message(error)
      })
  end

  defp resolve_zig!(zig) do
    diagnostic!("E_GODOT_OPTION_INVALID", ":zig must be an executable path", %{
      value: inspect(zig)
    })
  end

  defp resolve_godot!(nil) do
    case System.find_executable("godot") do
      nil ->
        diagnostic!("E_GODOT_EXECUTABLE_MISSING", "Godot is required for the load smoke", %{})

      godot ->
        resolve_godot!(godot)
    end
  end

  defp resolve_godot!(godot) when is_binary(godot) do
    case System.cmd(godot, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        version = String.trim(output)

        if String.starts_with?(version, @godot_api_version <> ".") or
             version == @godot_api_version do
          godot
        else
          diagnostic!(
            "E_GODOT_API_VERSION_MISMATCH",
            "load smoke requires the pinned Godot executable",
            %{actual: version, required: @godot_api_version}
          )
        end

      {output, status} ->
        diagnostic!("E_GODOT_EXECUTABLE_MISSING", "Godot version probe failed", %{
          exit_status: status,
          output: output
        })
    end
  rescue
    error in ErlangError ->
      diagnostic!("E_GODOT_EXECUTABLE_MISSING", "Godot executable could not be started", %{
        reason: Exception.message(error)
      })
  end

  defp verify_method_symbols!(archive, %BindingPlan{} = plan) do
    Batata.Export.verify_symbols!(archive, Enum.map(plan.methods, &%{"symbol" => &1.symbol}))
  rescue
    error in [ArgumentError, MatchError] ->
      diagnostic!(
        "E_GODOT_METHOD_SYMBOL_MISSING",
        "a declared Godot method is absent from the Batata archive",
        %{archive: Path.basename(archive), reason: Exception.message(error)},
        [%{command: "compile a Batata source module containing every declared method"}]
      )
  end

  defp link!(zig, %BindingPlan{} = plan, native, build_dir, library_path) do
    level = Map.fetch!(@initialization_levels, plan.initialization_level)
    install_dir = Path.join(build_dir, "godot-install")
    cache_dir = Path.join(build_dir, "godot-zig-cache")
    build_root = native_build_root()
    library_base = "#{plan.extension}.macos.debug.arm64"

    args = [
      "build",
      "godot-extension",
      "--prefix",
      install_dir,
      "--cache-dir",
      cache_dir,
      "-Doptimize=Debug",
      "-Dentry-symbol=#{plan.entry_symbol}",
      "-Dinitialization-level=#{level}",
      "-Dterm-runtime-source=#{Path.join(Batata.TermRuntime.native_dir(), "term_runtime.zig")}",
      "-Dbatata-object=#{native.object}",
      "-Druntime-library=#{native.runtime_lib}",
      "-Dlibrary-name=#{library_base}"
    ]

    try do
      case System.cmd(zig, args, stderr_to_stdout: true, cd: build_root) do
        {_output, 0} ->
          install_dir
          |> Path.join("lib")
          |> Path.join("lib#{library_base}.dylib")
          |> File.rename!(library_path)

        {output, status} ->
          diagnostic!("E_GODOT_LINK_FAILED", "Zig failed to link the GDExtension", %{
            exit_status: status,
            output: output
          })
      end
    after
      File.rm_rf(install_dir)
      File.rm_rf(cache_dir)
    end
  end

  defp verify_library_symbols!(library_path, %BindingPlan{} = plan) do
    symbols = [
      %{"symbol" => plan.entry_symbol} | Enum.map(plan.methods, &%{"symbol" => &1.symbol})
    ]

    Batata.Export.verify_symbols!(library_path, symbols)
  rescue
    error in [ArgumentError, MatchError] ->
      diagnostic!(
        "E_GODOT_ENTRY_SYMBOL_MISSING",
        "the linked library is missing a required exported symbol",
        %{library: Path.basename(library_path), reason: Exception.message(error)}
      )
  end

  defp write_metadata!(output_dir, plan, zig_version, artifacts) do
    artifact_paths = [
      artifacts[:binding_plan],
      artifacts[:gdextension],
      artifacts[:library]
    ]

    files =
      artifact_paths
      |> Enum.map(fn path ->
        %{"path" => Path.relative_to(path, output_dir), "sha256" => digest_file(path)}
      end)
      |> Enum.sort_by(& &1["path"])

    native_bundle = artifacts[:native].bundle |> File.read!() |> JSON.decode!()

    bundle = %{
      "adapter_implementation_sha256" => adapter_implementation_digest(),
      "binding_plan_sha256" => BindingPlan.digest(plan),
      "compatibility_minimum" => plan.compatibility_minimum,
      "entry_symbol" => plan.entry_symbol,
      "godot_api_sha256" => @godot_api_sha256,
      "godot_api_version" => @godot_api_version,
      "kind" => "godot_gdextension",
      "library" => Path.relative_to(artifacts[:library], output_dir),
      "native_artifact_sha256" => native_bundle["artifact_digest"],
      "schema_version" => 1,
      "target" => @target
    }

    manifest = %{
      "compiler" => "batata_godot",
      "elixir" => System.version(),
      "godot_api" => @godot_api_version,
      "godot_api_sha256" => @godot_api_sha256,
      "schema_version" => 1,
      "target" => @target,
      "version" => Application.spec(:batata_godot, :vsn) |> to_string(),
      "zig" => zig_version
    }

    bundle_path = Path.join(output_dir, "bundle.json")
    artifact_index_path = Path.join(output_dir, "artifact_index.json")
    manifest_path = Path.join(output_dir, "manifest.json")
    File.write!(bundle_path, JSON.encode!(bundle))
    File.write!(artifact_index_path, JSON.encode!(%{"files" => files}))
    File.write!(manifest_path, JSON.encode!(manifest))

    %{bundle: bundle_path, artifact_index: artifact_index_path, manifest: manifest_path}
  end

  defp digest_file(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp adapter_implementation_digest do
    [
      Path.join(native_build_root(), "build.zig"),
      Path.join(native_build_root(), "build.zig.zon"),
      Path.join(native_build_root(), "native/zig-src/main.zig")
    ]
    |> Enum.map_join(&digest_file/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp native_build_root do
    :batata_godot
    |> Application.app_dir("priv")
    |> canonical_path()
    |> Path.dirname()
  end

  defp canonical_path(path) do
    case File.read_link(path) do
      {:ok, resolved} ->
        case Path.type(resolved) do
          :absolute -> resolved
          :relative -> Path.expand(resolved, Path.dirname(path))
        end

      {:error, _reason} ->
        Path.expand(path)
    end
  end

  defp load_error?(output) do
    Enum.any?(
      [
        "ERROR:",
        "Failed loading GDExtension",
        "Can't open GDExtension",
        "GDExtension dynamic library not found",
        "Entry symbol not found"
      ],
      &String.contains?(output, &1)
    )
  end

  defp diagnostic!(code, message, context, actions \\ []) do
    raise Diagnostic, code: code, message: message, context: context, actions: actions
  end
end
