defmodule Batata.TermRuntime do
  @moduledoc """
  Builds and locates the Zig term runtime libraries.

  The runtime implements the declaration-first ABI in `native/ABI.md` and is
  consumed by the JIT (`Batata.execute/2`) through
  `MLIR.ExecutionEngine`'s `shared_lib_paths` so `ex.term.*` calls resolve to
  native symbols. The static library path for AOT linking is also exposed.
  """

  @doc "Directory containing the Zig runtime sources."
  @spec native_dir() :: Path.t()
  def native_dir do
    :batata
    |> Application.app_dir("priv")
    |> canonical_path()
    |> Path.dirname()
    |> Path.join("native")
  end

  @doc "Digest of the declaration-first term runtime ABI contract."
  @spec abi_digest() :: String.t()
  def abi_digest do
    digest =
      native_dir()
      |> Path.join("ABI.md")
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  @doc "Directory where built runtime artifacts are written."
  @spec priv_dir() :: Path.t()
  def priv_dir, do: Application.app_dir(:batata, "priv/term_runtime")

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
  Ensures the shared library exists, building it with the pinned Zig build
  graph when missing. Returns the shared library path.
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

  # Rebuild when any Zig source or build contract is newer than the artifact,
  # so pulling runtime or comptime-extension changes cannot retain stale code.
  defp stale?(path) do
    build_sources()
    |> Enum.any?(&(File.stat!(&1).mtime > File.stat!(path).mtime))
  end

  defp build_and_publish!(kind, path) do
    temporary = temporary_path(path)
    File.mkdir_p!(Path.dirname(path))

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
    zig_build!("term-runtime-shared", shared_lib_name(), path)
  end

  defp build!(:static, path) do
    zig_build!("term-runtime-static", static_lib_name(), path)
  end

  defp zig_build!(step, installed_name, path) do
    zig = System.find_executable("zig") || raise "zig not found on PATH"
    prefix = path <> ".install"
    cache = path <> ".zig-cache"

    try do
      {output, status} =
        System.cmd(
          zig,
          [
            "build",
            step,
            "--prefix",
            prefix,
            "--cache-dir",
            cache,
            "-Doptimize=ReleaseSafe"
          ],
          stderr_to_stdout: true,
          cd: build_root()
        )

      if status != 0 do
        raise "failed to build the Zig term runtime:\n#{output}"
      end

      prefix
      |> Path.join("lib")
      |> Path.join(installed_name)
      |> File.rename!(path)
    after
      File.rm_rf!(prefix)
      File.rm_rf!(cache)
    end
  end

  defp build_root, do: Path.dirname(native_dir())

  defp build_sources do
    Path.wildcard(Path.join(native_dir(), "**/*.zig")) ++
      [Path.join(build_root(), "build.zig"), Path.join(build_root(), "build.zig.zon")]
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
end
