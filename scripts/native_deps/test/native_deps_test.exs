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
    {beaver, kinda, _beaver_ref, _kinda_ref} = editable_repos!(root)
    llvm = fake_llvm!(root)
    zig = fake_zig!(root)

    config =
      Resolver.setup!(
        Keyword.merge(opts,
          beaver_path: beaver,
          kinda_path: kinda,
          llvm_config: llvm,
          zig_path: zig,
          fetch_deps: false
        )
      )

    assert config[:mode] == :editable
    assert config[:beaver_source] == :editable
    assert config[:kinda_source] == :editable
    assert config[:llvm_source] == :editable
    assert config[:llvm_revision] == "external-unverified"
    assert NativeDeps.config!(opts) == config
  end

  test "runner isolates build and deps per Batata worktree", %{
    root: root,
    cache: cache,
    opts: opts
  } do
    make_repo!(root, %{"workspace.ex" => "first"})
    {beaver, kinda, _beaver_ref, _kinda_ref} = editable_repos!(root)
    llvm = fake_llvm!(root)
    zig = fake_zig!(root)

    Resolver.setup!(
      Keyword.merge(opts,
        beaver_path: beaver,
        kinda_path: kinda,
        llvm_config: llvm,
        zig_path: zig,
        fetch_deps: false
      )
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

    File.write!(Path.join(root, "workspace.ex"), "second")
    git!(root, ["add", "workspace.ex"])
    git!(root, ["commit", "--quiet", "-m", "second"])
    next_context = Runner.context!(Keyword.put(opts, :zig_path, zig))

    assert Map.new(next_context.env)["MIX_BUILD_ROOT"] == env["MIX_BUILD_ROOT"]
    refute next_context.report[:batata] == context.report[:batata]
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
      "BEAVER_GIT_URL=#{beaver_repo}\nBEAVER_GIT_REF=#{beaver_ref}\n" <>
        "BEAVER_GIT_SHA=#{beaver_ref}\n"
    )

    zig = fake_zig!(root)

    config =
      Resolver.setup!(
        Keyword.merge(opts,
          llvm_config: fake_llvm!(root),
          zig_path: zig,
          fetch_deps: false
        )
      )

    assert config[:beaver_source] == :pinned
    assert config[:kinda_source] == :pinned
    assert config[:beaver_ref] == beaver_ref
    assert config[:kinda_ref] == kinda_ref
    assert String.starts_with?(config[:beaver_path], Path.join(cache, "sources/beaver/"))
    assert String.starts_with?(config[:kinda_path], Path.join(cache, "sources/kinda/"))
    assert File.regular?(NativeDeps.receipt_path(opts))
    assert :ok == Runner.verify!(Keyword.put(opts, :zig_path, zig))
  end

  test "fails closed when the receipt is missing or the lock changes", %{
    root: root,
    opts: opts
  } do
    {beaver, kinda, _beaver_ref, _kinda_ref} = editable_repos!(root)
    llvm = fake_llvm!(root)
    zig = fake_zig!(root)

    setup_opts =
      Keyword.merge(opts,
        beaver_path: beaver,
        kinda_path: kinda,
        llvm_config: llvm,
        zig_path: zig,
        fetch_deps: false
      )

    Resolver.setup!(setup_opts)
    File.rm!(NativeDeps.receipt_path(opts))

    assert_raise Mix.Error, ~r/native dependency receipt is missing/, fn ->
      Runner.verify!(Keyword.put(opts, :zig_path, zig))
    end

    Resolver.setup!(setup_opts)
    File.write!(Path.join(root, "native-deps.lock"), "# changed\n", [:append])

    assert_raise Mix.Error, ~r/native dependency lock changed since setup/, fn ->
      Runner.verify!(Keyword.put(opts, :zig_path, zig))
    end
  end

  test "rejects a fetch ref that does not match its expected SHA", %{
    root: root,
    opts: opts
  } do
    beaver_repo = Path.join(root, "beaver-origin")
    beaver_ref = make_repo!(beaver_repo, %{"README.md" => "beaver"})
    wrong_sha = String.duplicate("0", 40)

    File.write!(
      Path.join(root, "native-deps.lock"),
      "BEAVER_GIT_URL=#{beaver_repo}\nBEAVER_GIT_REF=#{beaver_ref}\n" <>
        "BEAVER_GIT_SHA=#{wrong_sha}\n"
    )

    assert_raise Mix.Error,
                 ~r/ref #{beaver_ref} resolved to #{beaver_ref}, expected #{wrong_sha}/,
                 fn ->
                   Resolver.setup!(Keyword.merge(opts, fetch_deps: false))
                 end
  end

  test "rejects dirty pinned source caches", %{root: root, opts: opts} do
    kinda_repo = Path.join(root, "kinda-origin")
    kinda_ref = make_repo!(kinda_repo, %{"README.md" => "kinda"})
    beaver_repo = Path.join(root, "beaver-origin")

    metadata =
      ~s({"schema_version":1,"kinda":{"git_url":"#{kinda_repo}","ref":"#{kinda_ref}"},"llvm":{"repo":"llvm/eudsl","tag":"llvm","default_revision":"revision"}})

    beaver_ref = make_repo!(beaver_repo, %{"native-deps.json" => metadata})

    File.write!(
      Path.join(root, "native-deps.lock"),
      "BEAVER_GIT_URL=#{beaver_repo}\nBEAVER_GIT_REF=#{beaver_ref}\n" <>
        "BEAVER_GIT_SHA=#{beaver_ref}\n"
    )

    zig = fake_zig!(root)

    config =
      Resolver.setup!(
        Keyword.merge(opts,
          llvm_config: fake_llvm!(root),
          zig_path: zig,
          fetch_deps: false
        )
      )

    File.write!(Path.join(config[:beaver_path], "untracked"), "dirty")

    assert_raise Mix.Error, ~r/pinned beaver checkout is dirty/, fn ->
      Runner.verify!(Keyword.put(opts, :zig_path, zig))
    end
  end

  test "uses an explicit editable workspace and tolerates normal dirty edits", %{
    root: root,
    opts: opts
  } do
    {beaver, kinda, beaver_ref, kinda_ref} = editable_repos!(root)
    workspace = Path.join([root, ".batata", "workspace.json"])
    File.mkdir_p!(Path.dirname(workspace))

    File.write!(
      workspace,
      :json.encode(%{
        "schema" => 1,
        "mode" => "editable",
        "beaver_path" => beaver,
        "kinda_path" => kinda
      })
    )

    zig = fake_zig!(root)

    config =
      Resolver.setup!(
        Keyword.merge(opts,
          llvm_config: fake_llvm!(root),
          zig_path: zig,
          fetch_deps: false
        )
      )

    assert config[:mode] == :editable
    assert config[:beaver_source] == :editable
    assert config[:beaver_base_ref] == beaver_ref
    assert config[:kinda_source] == :editable
    assert config[:kinda_base_ref] == kinda_ref

    File.write!(Path.join(beaver, "README.md"), "dirty")
    assert :ok == Runner.verify!(Keyword.put(opts, :zig_path, zig))
  end

  test "rejects an editable checkout outside the pinned ancestry", %{root: root, opts: opts} do
    {_beaver, kinda, _beaver_ref, _kinda_ref} = editable_repos!(root)
    unrelated = Path.join(root, "unrelated-beaver")
    make_repo!(unrelated, %{"native-deps.json" => "{}"})
    workspace = Path.join([root, ".batata", "workspace.json"])
    File.mkdir_p!(Path.dirname(workspace))

    File.write!(
      workspace,
      :json.encode(%{
        "schema" => 1,
        "mode" => "editable",
        "beaver_path" => unrelated,
        "kinda_path" => kinda
      })
    )

    assert_raise Mix.Error, ~r/editable beaver checkout does not descend from/, fn ->
      Resolver.setup!(
        Keyword.merge(opts,
          llvm_config: fake_llvm!(root),
          zig_path: fake_zig!(root),
          fetch_deps: false
        )
      )
    end
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

  test "workspace identity survives revisions but isolates paths", %{root: root} do
    repo = Path.join(root, "repo")
    make_repo!(repo, %{"tracked" => "first"})
    identity = Runner.workspace_identity(repo)

    File.write!(Path.join(repo, "tracked"), "second")
    git!(repo, ["add", "tracked"])
    git!(repo, ["commit", "--quiet", "-m", "second"])

    assert Runner.workspace_identity(repo) == identity
    refute Runner.workspace_identity(Path.join(root, "other")) == identity
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

  defp editable_repos!(root) do
    kinda = Path.join(root, "kinda")
    kinda_ref = make_repo!(kinda, %{"README.md" => "kinda"})
    beaver = Path.join(root, "beaver")

    metadata =
      ~s({"schema_version":1,"kinda":{"git_url":"#{kinda}","ref":"#{kinda_ref}"},"llvm":{"repo":"llvm/eudsl","tag":"llvm","default_revision":"revision"}})

    beaver_ref = make_repo!(beaver, %{"native-deps.json" => metadata})

    File.write!(
      Path.join(root, "native-deps.lock"),
      "BEAVER_GIT_URL=#{beaver}\nBEAVER_GIT_REF=#{beaver_ref}\n" <>
        "BEAVER_GIT_SHA=#{beaver_ref}\n"
    )

    {beaver, kinda, beaver_ref, kinda_ref}
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
