defmodule Batata.TermRuntimeTest do
  use ExUnit.Case, async: true

  test "Zig term runtime unit tests pass", %{} do
    zig = System.find_executable("zig") || raise "zig not found on PATH"
    source = Path.join(Batata.TermRuntime.native_dir(), "term_runtime.zig")

    {output, status} = System.cmd(zig, ["test", source], stderr_to_stdout: true)

    assert status == 0
    refute output =~ "FAIL"
  end
end
