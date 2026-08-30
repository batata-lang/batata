defmodule Batata.TermRuntimeTest do
  use ExUnit.Case, async: true

  test "derives a stable identity from the checked-in runtime ABI" do
    expected =
      Batata.TermRuntime.native_dir()
      |> Path.join("ABI.md")
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert Batata.TermRuntime.abi_digest() == "sha256:" <> expected
  end

  @tag :tmp_dir
  test "publishes one complete static runtime under concurrent demand", %{tmp_dir: tmp_dir} do
    path = Batata.TermRuntime.static_lib_path(dir: tmp_dir)
    File.rm(path)

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          built = Batata.TermRuntime.ensure_static_built!(dir: tmp_dir)
          {built, built |> File.read!() |> then(&:crypto.hash(:sha256, &1))}
        end,
        max_concurrency: 8,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [path]
    assert results |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1

    nm = System.find_executable("nm") || raise "nm not found on PATH"
    {symbols, 0} = System.cmd(nm, ["-g", path], stderr_to_stdout: true)
    assert symbols =~ "ex.term.runtime_create"
    refute symbols =~ "ex_term_runtime_create"

    temporary_pattern = Path.join(Path.dirname(path), ".*.tmp#{Path.extname(path)}")
    assert Path.wildcard(temporary_pattern) == []
  end

  @tag :tmp_dir
  test "Zig term runtime unit and comptime contract tests pass", %{tmp_dir: tmp_dir} do
    zig = System.find_executable("zig") || raise "zig not found on PATH"
    build_root = Batata.TermRuntime.native_dir() |> Path.dirname()

    {output, status} =
      System.cmd(
        zig,
        ["build", "test-runtime", "test-contracts", "--cache-dir", Path.join(tmp_dir, "cache")],
        stderr_to_stdout: true,
        cd: build_root
      )

    assert status == 0
    refute output =~ "FAIL"
  end
end
