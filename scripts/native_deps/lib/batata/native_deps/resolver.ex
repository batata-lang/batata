defmodule Batata.NativeDeps.Resolver do
  @moduledoc false

  alias Batata.NativeDeps
  alias Batata.NativeDeps.Command

  @cleared_env [
    {"BEAVER_PATH", nil},
    {"BEAVER_KINDA_PATH", nil},
    {"LLVM_CONFIG_PATH", nil},
    {"LLVM_PREBUILT_DIR", nil},
    {"LLVM_EUDSL_ASSET_NAME", nil},
    {"LLVM_EUDSL_ASSET_URL", nil},
    {"LLVM_EUDSL_ASSET_REVISION", nil},
    {"LLVM_EUDSL_SHA256", nil}
  ]

  def setup!(opts \\ []) do
    lock = NativeDeps.lock!(opts)

    beaver =
      source!(
        "beaver",
        opts[:beaver_path],
        Map.fetch!(lock, "BEAVER_GIT_URL"),
        Map.fetch!(lock, "BEAVER_GIT_REF"),
        opts
      )

    metadata = metadata!(beaver.path)

    kinda_meta = Map.fetch!(metadata, "kinda")

    kinda =
      source!(
        "kinda",
        opts[:kinda_path],
        Map.fetch!(kinda_meta, "git_url"),
        Map.fetch!(kinda_meta, "ref"),
        opts
      )

    llvm = llvm!(opts[:llvm_config], beaver.path, Map.fetch!(metadata, "llvm"), opts)

    config = [
      beaver_path: beaver.path,
      beaver_source: beaver.source,
      beaver_ref: beaver.ref,
      kinda_path: kinda.path,
      kinda_source: kinda.source,
      kinda_ref: kinda.ref,
      llvm_config_path: llvm.path,
      llvm_source: llvm.source,
      llvm_revision: llvm.revision,
      metadata_schema: Map.fetch!(metadata, "schema_version")
    ]

    NativeDeps.write_config!(config, opts)

    if Keyword.get(opts, :fetch_deps, true) do
      Batata.NativeDeps.Runner.run_mix!(["deps.get"], opts)
    end

    config
  end

  def metadata!(beaver_path) do
    path = Path.join(beaver_path, "native-deps.json")

    with {:ok, content} <- File.read(path),
         {:ok, metadata} <- decode_json(content),
         1 <- metadata["schema_version"],
         %{"git_url" => url, "ref" => ref} when is_binary(url) and is_binary(ref) <-
           metadata["kinda"],
         %{"repo" => repo, "tag" => tag, "default_revision" => revision}
         when is_binary(repo) and is_binary(tag) and is_binary(revision) <- metadata["llvm"] do
      metadata
    else
      {:error, reason} ->
        Mix.raise("cannot read Beaver toolchain metadata at #{path}: #{inspect(reason)}")

      _ ->
        Mix.raise("unsupported or incomplete Beaver toolchain metadata at #{path}")
    end
  end

  def validate_config!(config) do
    validate_directory!(Keyword.fetch!(config, :beaver_path), "Beaver checkout")
    validate_directory!(Keyword.fetch!(config, :kinda_path), "Kinda checkout")
    validate_llvm!(Keyword.fetch!(config, :llvm_config_path))
    config
  end

  defp source!(name, explicit, url, ref, opts) do
    if explicit do
      path = Path.expand(explicit)
      validate_directory!(path, String.capitalize(name) <> " checkout")
      %{path: path, source: :override, ref: git_revision(path) || "unversioned"}
    else
      path =
        Path.join([NativeDeps.cache_root(opts), "sources", name, NativeDeps.digest([url, ref])])

      checkout!(path, url, ref)
      %{path: path, source: :pinned, ref: ref}
    end
  end

  defp checkout!(path, url, ref) do
    Mix.Sync.Lock.with_lock(path, fn ->
      unless valid_checkout?(path, ref) do
        if File.exists?(path), do: File.rm_rf!(path)
        File.mkdir_p!(path)
        Command.run!("git", ["init", "--quiet", path])
        Command.run!("git", ["-C", path, "remote", "add", "origin", url])
        Command.run!("git", ["-C", path, "fetch", "--quiet", "--depth", "1", "origin", ref])
        Command.run!("git", ["-C", path, "checkout", "--quiet", "--detach", "FETCH_HEAD"])
      end
    end)

    unless valid_checkout?(path, ref), do: Mix.raise("cached #{path} does not resolve to #{ref}")
  end

  defp valid_checkout?(path, ref) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {head, 0} -> String.trim(head) == resolve_ref(path, ref)
      _ -> false
    end
  end

  defp resolve_ref(path, ref) do
    case System.cmd("git", ["-C", path, "rev-parse", ref], stderr_to_stdout: true) do
      {resolved, 0} -> String.trim(resolved)
      _ -> ref
    end
  end

  defp llvm!(explicit, _beaver_path, _metadata, _opts) when is_binary(explicit) do
    path = Path.expand(explicit)
    validate_llvm!(path)
    %{path: path, source: :override, revision: "external-unverified"}
  end

  defp llvm!(nil, beaver_path, metadata, opts) do
    revision = Map.fetch!(metadata, "default_revision")
    repo = Map.fetch!(metadata, "repo")
    tag = Map.fetch!(metadata, "tag")

    install_dir =
      Path.join([
        NativeDeps.cache_root(opts),
        "artifacts",
        "llvm",
        NativeDeps.digest([repo, tag, revision])
      ])

    llvm_config = Path.join([install_dir, "bin", NativeDeps.executable("llvm-config")])

    Mix.Sync.Lock.with_lock(install_dir, fn ->
      unless llvm_ready?(llvm_config) do
        installer = Path.join([beaver_path, "scripts", "install_llvm"])

        unless File.dir?(installer),
          do: Mix.raise("Beaver LLVM installer not found: #{installer}")

        Command.run!(
          System.find_executable("mix") || "mix",
          [
            "beaver.install_prebuilt_llvm",
            "--install-dir",
            install_dir,
            "--repo",
            repo,
            "--tag",
            tag,
            "--asset-revision",
            revision
          ],
          cd: installer,
          env: @cleared_env,
          print_output: true
        )
      end
    end)

    validate_llvm!(llvm_config)
    %{path: llvm_config, source: :pinned, revision: revision}
  end

  defp validate_directory!(path, label) do
    unless File.dir?(path), do: Mix.raise("#{label} not found: #{path}")
  end

  defp validate_llvm!(path) do
    unless llvm_ready?(path),
      do: Mix.raise("llvm-config or its LLVM library directory is invalid: #{path}")

    :ok
  end

  defp llvm_ready?(path) do
    File.regular?(path) and executable_file?(path) and
      llvm_directory?(path, "--libdir") and llvm_directory?(path, "--includedir")
  end

  defp llvm_directory?(path, flag) do
    case System.cmd(path, [flag], stderr_to_stdout: true) do
      {directory, 0} -> File.dir?(String.trim(directory))
      _ -> false
    end
  end

  defp executable_file?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp git_revision(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {revision, 0} -> String.trim(revision)
      _ -> nil
    end
  end

  defp decode_json(content) do
    {:ok, :json.decode(content)}
  rescue
    error -> {:error, error}
  end
end
