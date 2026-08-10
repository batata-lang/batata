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
  @spec static_lib_path(keyword()) :: Path.t()
  def static_lib_path(opts \\ []) do
    Path.join(Keyword.get(opts, :dir, priv_dir()), static_lib_name())
  end

  @doc """
  Ensures the shared library exists, building it with `zig build-lib` when
  missing. Returns the shared library path.
  """
  @spec ensure_built!(keyword()) :: Path.t()
  def ensure_built!(opts \\ []) do
    ensure_artifact!(:dynamic, shared_lib_path(), Keyword.get(opts, :force, false))
  end

  @doc """
  Ensures the static archive exists for AOT linking.

  Set `dir:` to build into a custom directory (e.g. an ExUnit `@tag :tmp_dir`)
  instead of the shared `priv/term_runtime` directory, so tests that rebuild
  the artifact can run in parallel.
  """
  @spec ensure_static_built!(keyword()) :: Path.t()
  def ensure_static_built!(opts \\ []) do
    ensure_artifact!(:static, static_lib_path(opts), Keyword.get(opts, :force, false))
  end

  defp ensure_artifact!(kind, path, force?) do
    if not force? and fresh?(path) do
      path
    else
      ensure_under_lock!(kind, path, force?)
    end
  end

  defp ensure_under_lock!(kind, path, force?) do
    lock = {{__MODULE__, Path.expand(path)}, self()}

    case :global.trans(lock, fn -> refresh_artifact!(kind, path, force?) end, [node()]) do
      {:aborted, reason} ->
        raise "failed to lock Batata runtime artifact #{path}: #{inspect(reason)}"

      result ->
        result
    end
  end

  defp refresh_artifact!(kind, path, force?) do
    if force? or not fresh?(path), do: build_and_publish!(kind, path)
    path
  end

  defp fresh?(path), do: usable?(path) and not stale?(path)

  defp usable?(path), do: File.exists?(path) and File.stat!(path).size > 0

  # Rebuild when the Zig sources are newer than the built library, so pulling
  # new intrinsics (or any runtime change) does not silently keep using the
  # previous binary.
  defp stale?(path) do
    source = Path.join(native_dir(), "term_runtime.zig")

    File.exists?(source) and File.stat!(source).mtime > File.stat!(path).mtime
  end

  defp build_and_publish!(kind, path) do
    temporary = temporary_path(path)

    try do
      build!(kind, temporary)
      publish!(temporary, path)
    after
      File.rm(temporary)
    end
  end

  defp temporary_path(path) do
    extension = Path.extname(path)
    basename = Path.basename(path, extension)
    unique = "#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"

    Path.join(Path.dirname(path), ".#{basename}.#{unique}.tmp#{extension}")
  end

  defp publish!(temporary, path) do
    case File.rename(temporary, path) do
      :ok ->
        :ok

      # POSIX rename replaces atomically. Windows does not replace an existing
      # destination, but callers in this VM still hold the artifact lock.
      {:error, :eexist} ->
        File.rm!(path)
        File.rename!(temporary, path)

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "publish Batata runtime artifact",
          path: path
    end
  end

  defp build!(:dynamic, path) do
    zig!([
      "build-lib",
      source_path(),
      "-dynamic",
      "-O",
      "ReleaseSafe",
      "-lc",
      "-femit-bin=#{path}"
    ])
  end

  defp build!(:static, path) do
    # `-fno-stack-check`: the Zig std references `__zig_probe_stack`, which a
    # plain C linker (the AOT driver) cannot resolve; the JIT path does not
    # need this flag.
    zig!([
      "build-lib",
      source_path(),
      "-O",
      "ReleaseSafe",
      "-lc",
      "-fno-stack-check",
      "-femit-bin=#{path}"
    ])
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
