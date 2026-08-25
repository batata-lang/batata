defmodule Batata.ObjC.Build do
  @moduledoc "Builds and receipts the fixed Objective-C runtime adapter."

  alias Batata.ObjC.{BindingPlan, Diagnostic, Ownership, Platform}

  @zig_version "0.16.0"
  @option_keys [:zig]

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
