defmodule Batata.NativeDepsTest do
  use ExUnit.Case, async: true

  alias Batata.NativeDeps
  alias Batata.NativeDeps.Resolver
  alias Batata.NativeDeps.Runner

  setup do
    base =
      Path.join(System.tmp_dir!(), "batata-native-deps-#{System.unique_integer([:positive])}")

    root = Path.join(base, "batata")
    cache = Path.join(base, "cache")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, root: root, cache: cache, opts: [root: root, cache_root: cache]}
  end

  test "round-trips a worktree-local configuration", %{opts: opts} do
    config = [beaver_path: "/tmp/beaver path", llvm_source: :override]
    NativeDeps.write_config!(config, opts)
    assert NativeDeps.config!(opts) == config
  end

  test "resolves explicit sources and records unverified overrides", %{root: root, opts: opts} do
    beaver = Path.join(root, "beaver")
    kinda = Path.join(root, "kinda")
    llvm = fake_llvm!(root)
    File.mkdir_p!(kinda)
    File.mkdir_p!(beaver)

    File.write!(
      Path.join(root, "native-deps.lock"),
      "BEAVER_GIT_URL=unused\nBEAVER_GIT_REF=#{String.duplicate("a", 40)}\n"
    )

    File.write!(Path.join(beaver, "native-deps.json"), """
    {"schema_version":1,"kinda":{"git_url":"unused","ref":"#{String.duplicate("b", 40)}"},"llvm":{"repo":"llvm/eudsl","tag":"llvm","default_revision":"revision"}}
    """)

    config =
      Resolver.setup!(
        Keyword.merge(opts,
          beaver_path: beaver,
          kinda_path: kinda,
          llvm_config: llvm,
          fetch_deps: false
        )
      )

    assert config[:beaver_source] == :override
    assert config[:kinda_source] == :override
    assert config[:llvm_source] == :override
    assert config[:llvm_revision] == "external-unverified"
    assert NativeDeps.config!(opts) == config
  end

  test "runner isolates build and deps per Batata worktree", %{
    root: root,
    cache: cache,
    opts: opts
  } do
    beaver = Path.join(root, "beaver")
    kinda = Path.join(root, "kinda")
    File.mkdir_p!(beaver)
    File.mkdir_p!(kinda)
    llvm = fake_llvm!(root)
    zig = fake_zig!(root)

    NativeDeps.write_config!(
      [
        beaver_path: beaver,
        beaver_source: :override,
        beaver_ref: "unversioned",
        kinda_path: kinda,
        kinda_source: :override,
        kinda_ref: "unversioned",
        llvm_config_path: llvm,
        llvm_source: :override,
        llvm_revision: "external-unverified",
        metadata_schema: 1
      ],
      opts
    )

    context = Runner.context!(Keyword.put(opts, :zig_path, zig))
    env = Map.new(context.env)

    assert env["MIX_DEPS_PATH"] == Path.join(root, ".batata/deps")
    assert String.starts_with?(env["MIX_BUILD_ROOT"], Path.join(root, ".batata/build/"))
    assert env["MIX_BUILD_PATH"] == nil
    assert env["BEAVER_PATH"] == beaver
    assert env["BEAVER_KINDA_PATH"] == kinda
    assert env["LLVM_CONFIG_PATH"] == llvm
    assert env["ZIG_GLOBAL_CACHE_DIR"] == Path.join(cache, "zig-global")
  end

  test "materializes pinned Beaver and Kinda checkouts in the shared cache", %{
    root: root,
    cache: cache,
    opts: opts
  } do
    kinda_repo = Path.join(root, "kinda-origin")
    kinda_ref = make_repo!(kinda_repo, %{"README.md" => "kinda"})
    beaver_repo = Path.join(root, "beaver-origin")

    metadata =
      ~s({"schema_version":1,"kinda":{"git_url":"#{kinda_repo}","ref":"#{kinda_ref}"},"llvm":{"repo":"llvm/eudsl","tag":"llvm","default_revision":"revision"}})

    beaver_ref = make_repo!(beaver_repo, %{"native-deps.json" => metadata})

    File.write!(
      Path.join(root, "native-deps.lock"),
      "BEAVER_GIT_URL=#{beaver_repo}\nBEAVER_GIT_REF=#{beaver_ref}\n"
    )

    config =
      Resolver.setup!(
        Keyword.merge(opts,
          llvm_config: fake_llvm!(root),
          fetch_deps: false
        )
      )

    assert config[:beaver_source] == :pinned
    assert config[:kinda_source] == :pinned
    assert config[:beaver_ref] == beaver_ref
    assert config[:kinda_ref] == kinda_ref
    assert String.starts_with?(config[:beaver_path], Path.join(cache, "sources/beaver/"))
    assert String.starts_with?(config[:kinda_path], Path.join(cache, "sources/kinda/"))
  end

  test "source identity distinguishes paths and diagnoses dirty repositories", %{root: root} do
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    File.write!(Path.join(repo, "tracked"), "clean")
    git!(repo, ["add", "tracked"])
    git!(repo, ["commit", "--quiet", "-m", "initial"])

    clean = Runner.source_identity(repo)
    refute String.ends_with?(clean, "-dirty")

    File.write!(Path.join(repo, "tracked"), "dirty")
    assert Runner.source_identity(repo) == clean <> "-dirty"
  end

  defp fake_llvm!(root) do
    bin = Path.join(root, "llvm/bin")
    lib = Path.join(root, "llvm/lib")
    include = Path.join(root, "llvm/include")
    File.mkdir_p!(bin)
    File.mkdir_p!(lib)
    File.mkdir_p!(include)
    path = Path.join(bin, "llvm-config")

    File.write!(
      path,
      "#!/bin/sh\ncase \"$1\" in --libdir) echo '#{lib}';; --includedir) echo '#{include}';; --version) echo '22.0.0';; *) exit 1;; esac\n"
    )

    File.chmod!(path, 0o755)
    path
  end

  defp fake_zig!(root) do
    path = Path.join(root, "zig")
    File.write!(path, "#!/bin/sh\necho '0.15.1'\n")
    File.chmod!(path, 0o755)
    path
  end

  defp git!(repo, args) do
    assert {_output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  end

  defp make_repo!(path, files) do
    File.mkdir_p!(path)
    git!(path, ["init", "--quiet"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Test"])

    for {name, content} <- files do
      target = Path.join(path, name)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
    end

    git!(path, ["add", "."])
    git!(path, ["commit", "--quiet", "-m", "fixture"])
    {revision, 0} = System.cmd("git", ["-C", path, "rev-parse", "HEAD"])
    String.trim(revision)
  end
end
