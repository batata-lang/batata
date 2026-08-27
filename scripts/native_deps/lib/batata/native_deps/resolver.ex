defmodule Batata.NativeDeps.Resolver do
  @moduledoc false

  alias Batata.NativeDeps
  alias Batata.NativeDeps.Command
  alias Batata.NativeDeps.Receipt
  alias Batata.NativeDeps.Workspace

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
    NativeDeps.remove_receipt!(opts)
    lock = NativeDeps.lock!(opts)
    workspace = Workspace.load!(opts)
    beaver_path = Workspace.select_path!(workspace, opts, :beaver_path)

    beaver =
      source!(
        "beaver",
        beaver_path,
        Map.fetch!(lock, "BEAVER_GIT_URL"),
        Map.fetch!(lock, "BEAVER_GIT_REF"),
        Map.fetch!(lock, "BEAVER_GIT_SHA"),
        opts
      )

    metadata =
      metadata!(beaver.path,
        require_default_revision: is_nil(opts[:llvm_config])
      )

    kinda_meta = Map.fetch!(metadata, "kinda")
    kinda_path = Workspace.select_path!(workspace, opts, :kinda_path)

    kinda =
      source!(
        "kinda",
        kinda_path,
        Map.fetch!(kinda_meta, "git_url"),
        Map.fetch!(kinda_meta, "ref"),
        Map.fetch!(kinda_meta, "ref"),
        opts
      )

    llvm = llvm!(opts[:llvm_config], beaver.path, Map.fetch!(metadata, "llvm"), opts)

    mode =
      if Enum.any?([beaver.source, kinda.source, llvm.source], &(&1 == :editable)),
        do: :editable,
        else: :pinned

    config = [
      schema: 1,
      mode: mode,
      lock_sha256: NativeDeps.file_sha256!(NativeDeps.lock_path(opts)),
      beaver_path: beaver.path,
      beaver_source: beaver.source,
      beaver_ref: beaver.ref,
      beaver_base_ref: beaver.base_ref,
      beaver_metadata_sha256: NativeDeps.file_sha256!(Path.join(beaver.path, "native-deps.json")),
      kinda_path: kinda.path,
      kinda_source: kinda.source,
      kinda_ref: kinda.ref,
      kinda_base_ref: kinda.base_ref,
      llvm_config_path: llvm.path,
      llvm_source: llvm.source,
      llvm_revision: llvm.revision,
      metadata_schema: Map.fetch!(metadata, "schema_version")
    ]

    NativeDeps.write_config!(config, opts)
    Receipt.write!(config, opts)

    if Keyword.get(opts, :fetch_deps, true) do
      Batata.NativeDeps.Runner.run_mix!(["deps.get"], opts)
    end

    config
  end

  def metadata!(beaver_path, opts \\ []) do
    path = Path.join(beaver_path, "native-deps.json")

    with {:ok, content} <- File.read(path),
         {:ok, metadata} <- decode_json(content),
         {:ok, metadata} <- normalize_metadata(metadata, opts) do
      metadata
    else
      {:error, reason} ->
        Mix.raise("cannot read Beaver toolchain metadata at #{path}: #{inspect(reason)}")

      _ ->
        Mix.raise("unsupported or incomplete Beaver toolchain metadata at #{path}")
    end
  end

  @doc false
  def platform_key do
    os =
      case :os.type() do
        {:unix, :darwin} -> "macos"
        {:unix, _name} -> "manylinux"
        {:win32, _name} -> "windows"
      end

    architecture =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.downcase()

    arm? = architecture =~ "aarch64" or architecture =~ "arm64"

    arch =
      case {os, arm?} do
        {"macos", true} ->
          "arm64"

        {"macos", false} ->
          "x86_64"

        {"windows", _arm?} ->
          "amd64"

        {_os, true} ->
          "aarch64"

        {_os, false} ->
          if architecture =~ "x86_64" or architecture =~ "amd64" do
            "x86_64"
          else
            Mix.raise("unsupported native dependency architecture: #{architecture}")
          end
      end

    "#{os}_#{arch}"
  end

  defp normalize_metadata(
         %{
           "schema_version" => 1,
           "kinda" => %{"git_url" => url, "ref" => ref},
           "llvm" => %{
             "repo" => repo,
             "tag" => tag,
             "default_revision" => revision
           }
         } = metadata,
         _opts
       )
       when is_binary(url) and is_binary(ref) and is_binary(repo) and is_binary(tag) and
              is_binary(revision),
       do: {:ok, metadata}

  defp normalize_metadata(
         %{
           "schema_version" => 2,
           "kinda" => %{"git_url" => url, "ref" => ref},
           "llvm" =>
             %{
               "repo" => repo,
               "tag" => tag,
               "default_revisions" => revisions
             } = llvm
         } = metadata,
         opts
       )
       when is_binary(url) and is_binary(ref) and is_binary(repo) and is_binary(tag) and
              is_map(revisions) do
    platform = platform_key()

    case Map.get(revisions, platform) do
      revision when is_binary(revision) ->
        {:ok, put_in(metadata, ["llvm"], Map.put(llvm, "default_revision", revision))}

      _missing ->
        if Keyword.get(opts, :require_default_revision, true) do
          {:error, {:missing_llvm_revision, platform}}
        else
          {:ok, metadata}
        end
    end
  end

  defp normalize_metadata(_metadata, _opts), do: {:error, :unsupported_schema}

  def validate_config!(config, opts \\ []) do
    unless Keyword.get(config, :schema) == 1,
      do: Mix.raise("native dependency configuration has an unsupported schema")

    unless Keyword.get(config, :mode) in [:pinned, :editable],
      do: Mix.raise("native dependency configuration has an unsupported mode")

    validate_digest!(
      NativeDeps.lock_path(opts),
      Keyword.fetch!(config, :lock_sha256),
      "native dependency lock"
    )

    validate_directory!(Keyword.fetch!(config, :beaver_path), "Beaver checkout")
    validate_directory!(Keyword.fetch!(config, :kinda_path), "Kinda checkout")
    validate_source!(config, :beaver)
    validate_source!(config, :kinda)

    validate_digest!(
      Path.join(Keyword.fetch!(config, :beaver_path), "native-deps.json"),
      Keyword.fetch!(config, :beaver_metadata_sha256),
      "Beaver native dependency metadata"
    )

    validate_llvm!(Keyword.fetch!(config, :llvm_config_path))
    config
  end

  defp source!(name, explicit, url, ref, expected_sha, opts) do
    if explicit do
      path = Path.expand(explicit, NativeDeps.root(opts))
      validate_directory!(path, String.capitalize(name) <> " checkout")
      validate_editable_base!(path, expected_sha, name)

      %{
        path: path,
        source: :editable,
        ref: git_revision(path),
        base_ref: expected_sha
      }
    else
      path =
        Path.join([
          NativeDeps.cache_root(opts),
          "sources",
          name,
          NativeDeps.digest([url, ref, expected_sha])
        ])

      checkout!(path, url, ref, expected_sha)
      %{path: path, source: :pinned, ref: expected_sha, base_ref: expected_sha}
    end
  end

  defp checkout!(path, url, ref, expected_sha) do
    Mix.Sync.Lock.with_lock(path, fn ->
      unless valid_checkout?(path, expected_sha) do
        if File.exists?(path), do: File.rm_rf!(path)
        File.mkdir_p!(path)
        Command.run!("git", ["init", "--quiet", path])
        Command.run!("git", ["-C", path, "remote", "add", "origin", url])
        Command.run!("git", ["-C", path, "fetch", "--quiet", "--depth", "1", "origin", ref])

        fetched_sha = git_revision(path, "FETCH_HEAD")

        if fetched_sha != expected_sha do
          Mix.raise(
            "#{url} ref #{ref} resolved to #{fetched_sha || "an invalid commit"}, " <>
              "expected #{expected_sha}"
          )
        end

        Command.run!("git", ["-C", path, "checkout", "--quiet", "--detach", "FETCH_HEAD"])
      end
    end)

    unless valid_checkout?(path, expected_sha),
      do: Mix.raise("cached #{path} does not resolve to #{expected_sha}")
  end

  defp valid_checkout?(path, expected_sha), do: git_revision(path) == expected_sha

  defp llvm!(explicit, _beaver_path, _metadata, _opts) when is_binary(explicit) do
    path = Path.expand(explicit)
    validate_llvm!(path)
    %{path: path, source: :editable, revision: "external-unverified"}
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

  defp validate_digest!(path, expected, label) do
    actual = NativeDeps.file_sha256!(path)

    unless actual == expected,
      do: Mix.raise("#{label} changed since setup; run 'mix batata.native setup'")
  end

  defp validate_source!(config, name) do
    path = Keyword.fetch!(config, String.to_existing_atom("#{name}_path"))
    source = Keyword.fetch!(config, String.to_existing_atom("#{name}_source"))
    expected = Keyword.fetch!(config, String.to_existing_atom("#{name}_ref"))
    base_ref = Keyword.fetch!(config, String.to_existing_atom("#{name}_base_ref"))

    case source do
      :pinned ->
        unless git_revision(path) == expected,
          do: Mix.raise("pinned #{name} checkout does not match #{expected}")

        dirty =
          Command.run!("git", [
            "-C",
            path,
            "status",
            "--porcelain",
            "--untracked-files=normal"
          ])

        unless String.trim(dirty) == "",
          do: Mix.raise("pinned #{name} checkout is dirty: #{path}")

      :editable ->
        validate_editable_base!(path, base_ref, name)

      other ->
        Mix.raise("unsupported #{name} source mode: #{inspect(other)}")
    end
  end

  defp validate_editable_base!(path, base_ref, name) do
    unless git_revision(path) do
      Mix.raise("editable #{name} path is not a Git checkout: #{path}")
    end

    case System.cmd(
           "git",
           ["-C", path, "merge-base", "--is-ancestor", base_ref, "HEAD"],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      _ -> Mix.raise("editable #{name} checkout does not descend from #{base_ref}: #{path}")
    end
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

  defp git_revision(path, ref \\ "HEAD") do
    case System.cmd("git", ["-C", path, "rev-parse", ref], stderr_to_stdout: true) do
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
