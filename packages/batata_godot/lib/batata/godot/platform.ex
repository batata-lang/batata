defmodule Batata.Godot.Platform do
  @moduledoc false

  alias Batata.Godot.Diagnostic

  @platforms [
    %{
      target: "aarch64-apple-darwin",
      feature: "macos.debug.arm64",
      suffix: ".dylib",
      prefix: "lib"
    },
    %{
      target: "x86_64-apple-darwin",
      feature: "macos.debug.x86_64",
      suffix: ".dylib",
      prefix: "lib"
    },
    %{
      target: "x86_64-linux-gnu",
      feature: "linux.debug.x86_64",
      suffix: ".so",
      prefix: "lib"
    },
    %{
      target: "x86_64-pc-windows-msvc",
      feature: "windows.debug.x86_64",
      suffix: ".dll",
      prefix: ""
    }
  ]

  @type t :: %{
          target: String.t(),
          feature: String.t(),
          suffix: String.t(),
          prefix: String.t()
        }

  @spec all() :: [t()]
  def all, do: @platforms

  @spec supported_targets() :: [String.t()]
  def supported_targets, do: Enum.map(@platforms, & &1.target)

  @spec host!() :: t()
  def host! do
    architecture = :erlang.system_info(:system_architecture) |> List.to_string()

    case Enum.find(@platforms, &host_matches?(&1, :os.type(), architecture)) do
      nil ->
        raise Diagnostic,
          code: "E_GODOT_PLATFORM_UNSUPPORTED",
          message: "the host cannot produce a supported GDExtension artifact",
          context: %{host: architecture, supported: supported_targets()},
          actions: [%{command: "build on a supported macOS, Linux, or Windows host"}]

      platform ->
        platform
    end
  end

  @spec library_name(t(), String.t()) :: String.t()
  def library_name(platform, extension) when is_binary(extension) do
    platform.prefix <> extension <> "." <> platform.feature <> platform.suffix
  end

  @spec library_base(t(), String.t()) :: String.t()
  def library_base(platform, extension) when is_binary(extension) do
    extension <> "." <> platform.feature
  end

  @spec installed_library_name(t(), String.t()) :: String.t()
  def installed_library_name(platform, extension) when is_binary(extension) do
    platform.prefix <> library_base(platform, extension) <> platform.suffix
  end

  @spec library_table(String.t()) :: %{String.t() => String.t()}
  def library_table(extension) when is_binary(extension) do
    Map.new(@platforms, &{&1.feature, library_name(&1, extension)})
  end

  defp host_matches?(%{target: "aarch64-apple-darwin"}, {:unix, :darwin}, architecture),
    do:
      String.starts_with?(architecture, "aarch64-") or String.starts_with?(architecture, "arm64-")

  defp host_matches?(%{target: "x86_64-apple-darwin"}, {:unix, :darwin}, architecture),
    do: String.starts_with?(architecture, "x86_64-")

  defp host_matches?(%{target: "x86_64-linux-gnu"}, {:unix, os}, architecture)
       when os in [:linux, :linux_gnu],
       do: String.starts_with?(architecture, "x86_64-")

  defp host_matches?(%{target: "x86_64-pc-windows-msvc"}, {:win32, _family}, architecture),
    do:
      String.starts_with?(architecture, "x86_64-") or String.starts_with?(architecture, "amd64-")

  defp host_matches?(_platform, _os, _architecture), do: false
end
