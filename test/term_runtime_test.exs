defmodule Batata.TermRuntimeTest do
  use ExUnit.Case, async: true

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

  test "fixed actor soak matrix passes", %{} do
    zig = System.find_executable("zig") || raise "zig not found on PATH"
    native = Batata.TermRuntime.native_dir()

    {output, status} =
      System.cmd(
        zig,
        [
          "test",
          "--dep",
          "runtime",
          "-Mroot=#{Path.join(native, "runtime_soak_test.zig")}",
          "-Mruntime=#{Path.join(native, "term_runtime.zig")}",
          "-lc"
        ],
        stderr_to_stdout: true,
        env: [{"BATATA_SOAK_SEED", "0x6101"}, {"BATATA_SOAK_SCALE", "1"}]
      )

    assert status == 0, output
    refute output =~ "soak failure"
  end
end
