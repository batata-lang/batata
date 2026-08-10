defmodule Batata.TermRuntimeTest do
  use ExUnit.Case, async: false

  test "publishes one complete static runtime under concurrent demand" do
    path = Batata.TermRuntime.static_lib_path()
    File.rm(path)

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          built = Batata.TermRuntime.ensure_static_built!()
          {built, built |> File.read!() |> then(&:crypto.hash(:sha256, &1))}
        end,
        max_concurrency: 8,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [path]
    assert results |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1

    temporary_pattern = Path.join(Path.dirname(path), ".*.tmp#{Path.extname(path)}")
    assert Path.wildcard(temporary_pattern) == []
  end

  test "Zig term runtime unit tests pass", %{} do
    zig = System.find_executable("zig") || raise "zig not found on PATH"
    source = Path.join(Batata.TermRuntime.native_dir(), "term_runtime.zig")

    {output, status} =
      System.cmd(zig, ["test", source, "-lc"], stderr_to_stdout: true)

    assert status == 0
    refute output =~ "FAIL"
  end
end
