defmodule Batata.ObjC.Platform do
  @moduledoc "Closed macOS target matrix for the Objective-C adapter."

  alias Batata.ObjC.Diagnostic

  @platforms %{
    "aarch64-macos" => %{zig: "aarch64-macos", arch: "arm64", suffix: ".a"},
    "x86_64-macos" => %{zig: "x86_64-macos", arch: "x86_64", suffix: ".a"}
  }

  @doc "Returns one supported platform descriptor."
  @spec get!(String.t()) :: map()
  def get!(target) do
    case @platforms do
      %{^target => platform} -> Map.put(platform, :target, target)
      _ -> unsupported!(target)
    end
  end

  @doc "Returns the current macOS platform descriptor."
  @spec host!() :: map()
  def host! do
    case {:erlang.system_info(:system_architecture), :os.type()} do
      {architecture, {:unix, :darwin}} ->
        architecture = to_string(architecture)

        get!(
          if String.starts_with?(architecture, "aarch64"),
            do: "aarch64-macos",
            else: "x86_64-macos"
        )

      {architecture, os} ->
        unsupported!(%{architecture: to_string(architecture), os: inspect(os)})
    end
  end

  defp unsupported!(target) do
    raise Diagnostic,
      code: "E_OBJC_TARGET_UNSUPPORTED",
      message: "target is outside the Objective-C adapter matrix",
      context: %{target: inspect(target), supported: Map.keys(@platforms) |> Enum.sort()},
      actions: [%{command: "build on macOS arm64 or x86_64"}]
  end
end
