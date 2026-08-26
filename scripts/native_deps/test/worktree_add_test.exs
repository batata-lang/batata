defmodule Batata.WorktreeAddTest do
  use ExUnit.Case, async: true

  @worktree_add Path.expand("../../../script/worktree-add", __DIR__)

  setup do
    base =
      Path.join(System.tmp_dir!(), "batata-worktree-add-#{System.unique_integer([:positive])}")

    repo = Path.join(base, "repo")
    File.mkdir_p!(Path.join(repo, "script"))
    File.cp!(@worktree_add, Path.join(repo, "script/worktree-add"))
    File.chmod!(Path.join(repo, "script/worktree-add"), 0o755)
    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base, repo: repo}
  end

  test "creates and bootstraps a worktree", %{base: base, repo: repo} do
    bootstrap!(repo, "touch .ready\n")
    commit_fixture!(repo)
    target = Path.join(base, "ready")

    assert {output, 0} = run(repo, target, "feature/ready")
    assert output =~ "Worktree ready: #{canonical_path(target)}"
    assert File.regular?(Path.join(target, ".ready"))
    assert git_output!(repo, ["-C", target, "branch", "--show-current"]) == "feature/ready"
  end

  test "rolls back the exact worktree and newly-created branch on bootstrap failure", %{
    base: base,
    repo: repo
  } do
    bootstrap!(repo, "touch partial\nexit 17\n")
    commit_fixture!(repo)
    target = Path.join(base, "failed")

    assert {output, 17} = run(repo, target, "feature/fails")
    refute File.exists?(target)
    assert output =~ "worktree bootstrap failed; retry with:"

    refute match?(
             {_output, 0},
             System.cmd(
               "git",
               [
                 "-C",
                 repo,
                 "show-ref",
                 "--verify",
                 "refs/heads/feature/fails"
               ],
               stderr_to_stdout: true
             )
           )
  end

  test "does not alter a pre-existing target", %{base: base, repo: repo} do
    bootstrap!(repo, "touch .ready\n")
    commit_fixture!(repo)
    target = Path.join(base, "existing")
    File.mkdir_p!(target)
    marker = Path.join(target, "keep")
    File.write!(marker, "preserve")

    assert {output, 2} = run(repo, target, "feature/existing")
    assert output =~ "worktree path already exists"
    assert File.read!(marker) == "preserve"
  end

  defp bootstrap!(repo, body) do
    path = Path.join(repo, "script/bootstrap-worktree")

    File.write!(
      path,
      "#!/usr/bin/env bash\nset -euo pipefail\n" <>
        "script_dir=\"$(CDPATH= cd -- \"$(dirname -- \"${BASH_SOURCE[0]}\")\" && pwd -P)\"\n" <>
        "cd \"$(git -C \"$script_dir\" rev-parse --show-toplevel)\"\n#{body}"
    )

    File.chmod!(path, 0o755)
  end

  defp commit_fixture!(repo) do
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--quiet", "-m", "fixture"])
  end

  defp run(repo, target, branch) do
    System.cmd(Path.join(repo, "script/worktree-add"), [target, branch],
      cd: repo,
      stderr_to_stdout: true
    )
  end

  defp git_output!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp canonical_path(path) do
    {parent, 0} = System.cmd("pwd", ["-P"], cd: Path.dirname(path))
    Path.join(String.trim(parent), Path.basename(path))
  end

  defp git!(repo, args) do
    assert {_output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  end
end
