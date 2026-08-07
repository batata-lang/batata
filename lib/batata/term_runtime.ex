defmodule Batata.TermRuntime do
  @moduledoc """
  Builds and locates the Zig term runtime shared library.

  The runtime implements the declaration-first ABI in `native/ABI.md` and is
  consumed by the JIT (`Batata.execute/2`) through
  `MLIR.ExecutionEngine`'s `shared_lib_paths` so `ex.term.*` calls resolve to
  native symbols. The static library path for AOT linking is also exposed.
  """

  @doc "Directory containing the Zig runtime sources."
  @spec native_dir() :: Path.t()
  def native_dir, do: Path.expand("native", File.cwd!())

  @doc "Directory where built runtime artifacts are written."
  @spec priv_dir() :: Path.t()
  def priv_dir, do: Path.expand("priv/term_runtime", File.cwd!())

  @doc "Shared library file name for the current OS."
  @spec shared_lib_name() :: String.t()
  def shared_lib_name do
    case :os.type() do
      {:unix, :darwin} -> "libterm_runtime.dylib"
      {:unix, _} -> "libterm_runtime.so"
      {:win32, _} -> "term_runtime.dll"
    end
  end

  @doc "Static archive file name for the current OS."
  @spec static_lib_name() :: String.t()
  def static_lib_name do
    case :os.type() do
      {:win32, _} -> "term_runtime.lib"
      _ -> "libterm_runtime.a"
    end
  end

  @doc "Path of the shared library, built or not."
  @spec shared_lib_path() :: Path.t()
  def shared_lib_path, do: Path.join(priv_dir(), shared_lib_name())

  @doc "Path of the static archive, built or not."
  @spec static_lib_path() :: Path.t()
  def static_lib_path, do: Path.join(priv_dir(), static_lib_name())

  @doc """
  Ensures the shared library exists, building it with `zig build-lib` when
  missing. Returns the shared library path.
  """
  @spec ensure_built!(keyword()) :: Path.t()
  def ensure_built!(opts \\ []) do
    path = shared_lib_path()

    if usable?(path) and not Keyword.get(opts, :force, false) do
      path
    else
      build!(:dynamic, path)
      path
    end
  end

  @doc """
  Ensures the static archive exists for AOT linking.
  """
  @spec ensure_static_built!() :: Path.t()
  def ensure_static_built! do
    path = static_lib_path()
    if usable?(path), do: path, else: build!(:static, path)
  end

  defp usable?(path), do: File.exists?(path) and File.stat!(path).size > 0

  defp build!(:dynamic, path) do
    zig!(["build-lib", source_path(), "-dynamic", "-O", "ReleaseSafe", "-femit-bin=#{path}"])
  end

  defp build!(:static, path) do
    zig!(["build-lib", source_path(), "-O", "ReleaseSafe", "-femit-bin=#{path}"])
  end

  defp zig!(args) do
    zig = System.find_executable("zig") || raise "zig not found on PATH"
    File.mkdir_p!(priv_dir())

    {output, status} =
      System.cmd(zig, args, stderr_to_stdout: true, cd: File.cwd!())

    if status != 0 do
      raise "failed to build the Zig term runtime:\n#{output}"
    end

    :ok
  end

  defp source_path, do: Path.join(native_dir(), "term_runtime.zig")
end
