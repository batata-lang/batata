defmodule Batata.ObjC.Build do
  @moduledoc "Builds and receipts the fixed Objective-C runtime adapter."

  alias Batata.ObjC.AppKit.ApplicationPlan
  alias Batata.ObjC.{BindingPlan, Diagnostic, Ownership, Platform}

  @zig_version "0.16.0"
  @option_keys [:zig]
  @app_option_keys [:batata, :smoke, :zig]

  @type output :: %{
          archive: Path.t(),
          binding_plan: Path.t(),
          memory_effects: Path.t(),
          platform_receipt: Path.t()
        }

  @doc "Builds the fixed adapter for a validated binding plan."
  @spec build_runtime(BindingPlan.t(), Path.t(), keyword()) :: output()
  def build_runtime(%BindingPlan{} = plan, output_dir, options \\ [])
      when is_binary(output_dir) and is_list(options) do
    validate_options!(options)
    platform = Platform.get!(plan.target)
    {zig, zig_version} = resolve_zig!(options[:zig])
    sdk_root = resolve_sdk!(plan.sdk)
    root = package_root()
    output_dir = Path.expand(output_dir)
    File.mkdir_p!(output_dir)

    args = [
      "build",
      "objc-runtime",
      "-Dtarget=#{platform.zig}",
      "-Doptimize=ReleaseSafe",
      "--sysroot",
      sdk_root,
      "--prefix",
      output_dir
    ]

    case System.cmd(zig, args, cd: root, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> build_failed!(status, output)
    end

    archive = Path.join([output_dir, "lib", "libbatata_objc.a"])
    ensure_artifact!(archive)
    binding_plan = Path.join(output_dir, "binding_plan.json")
    memory_effects = Path.join(output_dir, "memory_effects.json")
    receipt = Path.join(output_dir, "platform_receipt.json")

    File.write!(binding_plan, BindingPlan.canonical_json(plan))
    File.write!(memory_effects, JSON.encode!(Ownership.summaries(plan)))

    File.write!(
      receipt,
      JSON.encode!(%{
        "adapter_digest" => adapter_digest(root),
        "archive" => %{
          "path" => Path.relative_to(archive, output_dir),
          "sha256" => file_digest(archive)
        },
        "binding_plan_digest" => BindingPlan.digest(plan),
        "minimum_macos" => plan.minimum_macos,
        "schema" => 1,
        "sdk" => plan.sdk,
        "sdk_digest" => plan.sdk_digest,
        "sdk_root" => sdk_root,
        "target" => plan.target,
        "zig" => zig_version
      })
    )

    %{
      archive: archive,
      binding_plan: binding_plan,
      memory_effects: memory_effects,
      platform_receipt: receipt
    }
  end

  @doc "Compiles Batata callbacks and packages a runnable AppKit application."
  @spec build_app(String.t(), ApplicationPlan.t(), Path.t(), Beaver.MLIR.Context.t(), keyword()) ::
          map()
  def build_app(source, %ApplicationPlan{} = application, output_dir, ctx, options \\ [])
      when is_binary(source) and is_binary(output_dir) and is_list(options) do
    validate_app_options!(options)
    binding = Batata.ObjC.appkit_plan(application.module)
    platform = Platform.get!(binding.target)
    {zig, zig_version} = resolve_zig!(options[:zig])
    sdk_root = resolve_sdk!(binding.sdk)
    output_dir = Path.expand(output_dir)
    native_dir = Path.join(output_dir, ".batata/native")
    contents = Path.join([output_dir, "#{application.name}.app", "Contents"])
    executable_dir = Path.join(contents, "MacOS")
    File.mkdir_p!(executable_dir)

    native = Batata.build(source, native_dir, ctx, Keyword.get(options, :batata, []))
    verify_callback_symbols!(native.archive, application)

    executable = link_app!(zig, sdk_root, application, native, output_dir, platform, options)

    bundled_executable = Path.join(executable_dir, application.name)
    File.cp!(executable, bundled_executable)
    File.chmod!(bundled_executable, 0o755)

    info_plist = Path.join(contents, "Info.plist")
    File.write!(info_plist, info_plist(application, binding))
    application_plan = Path.join(output_dir, "application_plan.json")
    binding_plan = Path.join(output_dir, "binding_plan.json")
    File.write!(application_plan, ApplicationPlan.canonical_json(application))
    File.write!(binding_plan, BindingPlan.canonical_json(binding))

    receipt = Path.join(output_dir, "app_receipt.json")

    File.write!(
      receipt,
      JSON.encode!(%{
        "adapter_digest" => adapter_digest(package_root()),
        "application_digest" => ApplicationPlan.digest(application),
        "artifacts" =>
          artifact_index(
            [bundled_executable, info_plist, application_plan, binding_plan],
            output_dir
          ),
        "batata_bundle_digest" => file_digest(native.bundle),
        "binding_plan_digest" => BindingPlan.digest(binding),
        "minimum_macos" => binding.minimum_macos,
        "schema" => 1,
        "sdk" => binding.sdk,
        "sdk_digest" => binding.sdk_digest,
        "smoke" => Keyword.get(options, :smoke, false),
        "target" => binding.target,
        "zig" => zig_version
      })
    )

    if Keyword.get(options, :smoke, false), do: smoke_app!(bundled_executable)

    %{
      app: Path.join(output_dir, "#{application.name}.app"),
      application_plan: application_plan,
      binding_plan: binding_plan,
      executable: bundled_executable,
      info_plist: info_plist,
      native: native,
      receipt: receipt
    }
  end

  defp validate_options!(options) do
    unknown = Keyword.keys(options) -- @option_keys

    if unknown != [] do
      raise Diagnostic,
        code: "E_OBJC_OPTION_INVALID",
        message: "unknown Objective-C build option",
        context: %{unknown: Enum.sort(unknown)},
        actions: [%{command: "remove unsupported build options"}]
    end
  end

  defp validate_app_options!(options) do
    unknown = Keyword.keys(options) -- @app_option_keys
    smoke = Keyword.get(options, :smoke, false)

    if unknown != [] or not is_boolean(smoke) do
      raise Diagnostic,
        code: "E_OBJC_OPTION_INVALID",
        message: "invalid AppKit build option",
        context: %{unknown: Enum.sort(unknown), smoke: inspect(smoke)},
        actions: [%{command: "use only :batata, :smoke and :zig options"}]
    end
  end

  defp resolve_zig!(configured) do
    zig = configured || System.find_executable("zig")

    if is_nil(zig) do
      raise Diagnostic,
        code: "E_OBJC_TOOL_MISSING",
        message: "Zig is required to build the Objective-C adapter",
        context: %{required: @zig_version},
        actions: [%{command: "install Zig #{@zig_version}"}]
    end

    case System.cmd(zig, ["version"], stderr_to_stdout: true) do
      {version, 0} ->
        version = String.trim(version)

        if version == @zig_version do
          {zig, version}
        else
          raise Diagnostic,
            code: "E_OBJC_TOOL_VERSION",
            message: "Zig version is outside the pinned adapter toolchain",
            context: %{expected: @zig_version, actual: version},
            actions: [%{command: "install Zig #{@zig_version}"}]
        end

      {output, status} ->
        build_failed!(status, output)
    end
  end

  defp adapter_digest(root) do
    root
    |> Path.join("native/**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map_join(fn path -> Path.relative_to(path, root) <> <<0>> <> File.read!(path) end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp link_app!(zig, sdk_root, application, native, output_dir, platform, options) do
    install_dir = Path.join(output_dir, ".batata/app-install")
    File.rm_rf!(install_dir)

    frame_args =
      [
        {"window", application.window},
        {"label", application.label},
        {"button", application.button}
      ]
      |> Enum.flat_map(fn {prefix, item} ->
        {x, y, width, height} = item.frame

        [
          "-D#{prefix}-x=#{x}",
          "-D#{prefix}-y=#{y}",
          "-D#{prefix}-width=#{width}",
          "-D#{prefix}-height=#{height}"
        ]
      end)

    args =
      [
        "build",
        "appkit-app",
        "-Dtarget=#{platform.zig}",
        "-Doptimize=ReleaseSafe",
        "--sysroot",
        sdk_root,
        "--prefix",
        install_dir,
        "-Dapp-name=#{application.name}",
        "-Dwindow-title=#{application.window.title}",
        "-Dlabel-text=#{application.label.text}",
        "-Dbutton-title=#{application.button.title}",
        "-Ddid-finish-symbol=#{application.callbacks.did_finish_launching}",
        "-Dbutton-symbol=#{application.callbacks.button_pressed}",
        "-Dshould-terminate-symbol=#{application.callbacks.should_terminate}",
        "-Dtrue-word=#{atom_word(true)}",
        "-Dsmoke=#{Keyword.get(options, :smoke, false)}",
        "-Dterm-runtime-source=#{Path.join(Batata.TermRuntime.native_dir(), "term_runtime.zig")}",
        "-Dbatata-object=#{native.object}",
        "-Druntime-library=#{native.runtime_lib}"
      ] ++ frame_args

    case System.cmd(zig, args, cd: package_root(), stderr_to_stdout: true) do
      {_output, 0} ->
        executable = Path.join([install_dir, "bin", application.name])
        ensure_artifact!(executable)
        executable

      {output, status} ->
        raise Diagnostic,
          code: "E_OBJC_NATIVE_BUILD_FAILED",
          message: "AppKit executable link failed",
          context: %{exit_status: status, output: output},
          actions: [%{command: "run the emitted zig build appkit-app command"}]
    end
  end

  defp verify_callback_symbols!(archive, application) do
    nm = System.find_executable("nm")

    {output, status} =
      if nm,
        do: System.cmd(nm, ["-g", archive], stderr_to_stdout: true),
        else: {"nm missing", 127}

    defined =
      output
      |> String.split("\n")
      |> Enum.map(fn line -> line |> String.split() |> List.last() end)
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn symbol -> [symbol, String.replace_prefix(symbol, "_", "")] end)
      |> MapSet.new()

    missing =
      application.callbacks
      |> Enum.map(fn {_name, symbol} -> symbol end)
      |> Enum.reject(&MapSet.member?(defined, &1))

    if status != 0 or missing != [] do
      raise Diagnostic,
        code: "E_OBJC_CALLBACK_SIGNATURE_MISMATCH",
        message: "a declared AppKit callback is absent from the Batata archive",
        context: %{archive: archive, missing: missing, nm_status: status, output: output},
        actions: [
          %{command: "define did_finish_launching/0, button_pressed/0 and should_terminate/0"}
        ]
    end
  end

  defp smoke_app!(executable) do
    case System.cmd(executable, [], stderr_to_stdout: true, env: [{"NSUnbufferedIO", "YES"}]) do
      {output, 0} ->
        required = [
          "BATATA_OBJC_CALLBACK did_finish_launching",
          "BATATA_OBJC_CALLBACK button_pressed",
          "BATATA_OBJC_CALLBACK should_terminate=true",
          "BATATA_OBJC_CLEAN_EXIT"
        ]

        missing = Enum.reject(required, &String.contains?(output, &1))

        if missing != [] do
          raise Diagnostic,
            code: "E_OBJC_APPKIT_SMOKE_FAILED",
            message: "AppKit smoke did not close every callback phase",
            context: %{missing: missing, output: output},
            actions: [%{command: "run the bundled executable under an active WindowServer"}]
        end

        :ok

      {output, status} ->
        raise Diagnostic,
          code: "E_OBJC_APPKIT_SMOKE_FAILED",
          message: "AppKit smoke exited unsuccessfully",
          context: %{exit_status: status, output: output},
          actions: [%{command: "inspect the Objective-C callback diagnostics"}]
    end
  end

  defp info_plist(application, binding) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key><string>#{application.name}</string>
      <key>CFBundleIdentifier</key><string>#{application.bundle_identifier}</string>
      <key>CFBundleName</key><string>#{application.name}</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>0.1.0</string>
      <key>LSMinimumSystemVersion</key><string>#{binding.minimum_macos}</string>
      <key>NSPrincipalClass</key><string>NSApplication</string>
    </dict>
    </plist>
    """
  end

  defp artifact_index(paths, root) do
    paths
    |> Enum.sort()
    |> Enum.map(fn path ->
      %{"path" => Path.relative_to(path, root), "sha256" => file_digest(path)}
    end)
  end

  defp atom_word(atom), do: (16 + :erlang.phash2(atom)) * 8 + 1

  defp resolve_sdk!(expected_version) do
    with xcrun when is_binary(xcrun) <- System.find_executable("xcrun"),
         {version, 0} <- System.cmd(xcrun, ["--sdk", "macosx", "--show-sdk-version"]),
         {root, 0} <- System.cmd(xcrun, ["--sdk", "macosx", "--show-sdk-path"]) do
      version = String.trim(version)
      root = String.trim(root)

      if version == expected_version and File.dir?(root) do
        root
      else
        raise Diagnostic,
          code: "E_OBJC_SDK_DRIFT",
          message: "installed macOS SDK does not match the binding plan",
          context: %{expected: expected_version, actual: version, sdk_root: root},
          actions: [%{command: "review and regenerate the Objective-C metadata manifest"}]
      end
    else
      result ->
        raise Diagnostic,
          code: "E_OBJC_TOOL_MISSING",
          message: "xcrun cannot resolve the macOS SDK",
          context: %{result: inspect(result)},
          actions: [%{command: "install Xcode and select it with xcode-select"}]
    end
  end

  defp ensure_artifact!(path) do
    unless File.regular?(path) do
      raise Diagnostic,
        code: "E_OBJC_ARTIFACT_MISSING",
        message: "Objective-C adapter build did not produce its archive",
        context: %{path: path},
        actions: [%{command: "inspect the Zig build output"}]
    end
  end

  defp file_digest(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  defp package_root, do: Path.expand("../../..", __DIR__)

  defp build_failed!(status, output) do
    raise Diagnostic,
      code: "E_OBJC_NATIVE_BUILD_FAILED",
      message: "Objective-C adapter build failed",
      context: %{exit_status: status, output: output},
      actions: [%{command: "run zig build test in packages/batata_objc"}]
  end
end
