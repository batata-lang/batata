defmodule Batata.NativeDeps.Runner do
  @moduledoc false

  alias Batata.NativeDeps
  alias Batata.NativeDeps.Command
  alias Batata.NativeDeps.Receipt
  alias Batata.NativeDeps.Resolver
  alias Batata.NativeDeps.Subprocess

  def doctor!(opts \\ []) do
    context = context!(opts)

    for {key, value} <- context.report do
      Mix.shell().info("#{key}=#{value}")
    end
  end

  def verify!(opts \\ []) do
    opts
    |> NativeDeps.config!()
    |> Resolver.validate_config!(opts)
    |> Receipt.verify!(opts)

    :ok
  end

  def run_mix!(args, opts \\ []) do
    run_command!(System.find_executable("mix") || "mix", args, opts)
  end

  def run_command!(command, args, opts \\ []) do
    context = context!(opts)

    status =
      Subprocess.run!(command, args,
        cd: NativeDeps.root(opts),
        env: context.env
      )

    if status != 0, do: Mix.raise("#{command} failed with status #{status}")
  end

  def context!(opts \\ []) do
    root = NativeDeps.root(opts)
    config = NativeDeps.config!(opts) |> Resolver.validate_config!(opts)
    Receipt.verify!(config, opts)
    llvm_config = Keyword.fetch!(config, :llvm_config_path)
    llvm_libdir = command!(llvm_config, ["--libdir"])
    llvm_includedir = command!(llvm_config, ["--includedir"])
    llvm_version = command!(llvm_config, ["--version"])

    zig =
      opts[:zig_path] || System.find_executable("zig") ||
        Mix.raise("zig is required but was not found")

    zig_version = command!(zig, ["version"])

    root_identity = source_identity(root)
    root_build_identity = workspace_identity(root)
    beaver_identity = source_identity(Keyword.fetch!(config, :beaver_path))
    kinda_identity = source_identity(Keyword.fetch!(config, :kinda_path))

    identity =
      NativeDeps.digest(
        [
          root_build_identity,
          beaver_identity,
          kinda_identity,
          llvm_config,
          llvm_version,
          llvm_libdir,
          llvm_includedir,
          to_string(:erlang.system_info(:otp_release)),
          System.version(),
          zig_version
        ],
        24
      )

    state_root = Path.join(root, ".batata")
    deps_path = Path.join(state_root, "deps")
    build_root = Path.join([state_root, "build", identity])
    zig_local = Path.join(build_root, "zig-cache")
    zig_global = Path.join(NativeDeps.cache_root(opts), "zig-global")
    File.mkdir_p!(zig_local)
    File.mkdir_p!(zig_global)

    env = [
      {"MIX_BUILD_PATH", nil},
      {"MIX_BUILD_ROOT", build_root},
      {"MIX_DEPS_PATH", deps_path},
      {"BEAVER_PATH", Keyword.fetch!(config, :beaver_path)},
      {"BEAVER_KINDA_PATH", Keyword.fetch!(config, :kinda_path)},
      {"LLVM_CONFIG_PATH", llvm_config},
      {"LLVM_PREBUILT_DIR", nil},
      {"LLVM_EUDSL_ASSET_NAME", nil},
      {"LLVM_EUDSL_ASSET_URL", nil},
      {"LLVM_EUDSL_ASSET_REVISION", nil},
      {"LLVM_EUDSL_SHA256", nil},
      {"ZIG_LOCAL_CACHE_DIR", zig_local},
      {"ZIG_GLOBAL_CACHE_DIR", zig_global}
    ]

    report = [
      identity: identity,
      batata: root_identity,
      beaver: beaver_identity,
      beaver_source: Keyword.fetch!(config, :beaver_source),
      kinda: kinda_identity,
      kinda_source: Keyword.fetch!(config, :kinda_source),
      llvm_config: llvm_config,
      llvm_version: llvm_version,
      llvm_libdir: llvm_libdir,
      llvm_includedir: llvm_includedir,
      llvm_source: Keyword.fetch!(config, :llvm_source),
      llvm_revision: Keyword.fetch!(config, :llvm_revision),
      deps_path: deps_path,
      build_root: build_root,
      zig_local_cache: zig_local,
      zig_global_cache: zig_global
    ]

    %{env: env, report: report}
  end

  def source_identity(path) do
    canonical = canonical_path(path)
    path_identity = workspace_identity(canonical)

    case System.cmd("git", ["-C", canonical, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} ->
        dirty =
          Command.run!("git", [
            "-C",
            canonical,
            "status",
            "--porcelain",
            "--untracked-files=normal"
          ])

        "#{path_identity}-#{String.trim(revision)}" <>
          if(String.trim(dirty) == "", do: "", else: "-dirty")

      _ ->
        "#{path_identity}-unversioned"
    end
  end

  @doc false
  def workspace_identity(path) do
    path
    |> canonical_path()
    |> then(&NativeDeps.digest([&1], 12))
    |> then(&"path-#{&1}")
  end

  defp canonical_path(path) do
    case :file.read_link_all(String.to_charlist(Path.expand(path))) do
      {:ok, resolved} -> List.to_string(resolved)
      _ -> Path.expand(path)
    end
  end

  defp command!(command, args), do: Command.run!(command, args) |> String.trim()
end
