defmodule Batata.AOTTest do
  use Batata.Case, async: true

  @moduletag timeout: 180_000

  alias Batata
  alias Batata.Test.Subprocess

  @child_timeout 15_000

  @tag :tmp_dir
  test "builds a static library and runs it from C", %{ctx: ctx, tmp_dir: tmp_dir} do
    output =
      Batata.build(
        """
        defmodule Math do
          def main() do
            a = 1 + 2
            a + 3
          end
        end
        """,
        tmp_dir,
        ctx
      )

    assert File.exists?(output.archive)
    assert File.exists?(output.driver)
    assert File.exists?(output.object)
    refute File.exists?(Path.join(tmp_dir, "batata.mlir"))
    refute File.exists?(Path.join(tmp_dir, "batata.ll"))

    binary = Path.join(tmp_dir, "run_math")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    {stdout, 0} = Subprocess.cmd(binary, timeout: @child_timeout)
    assert stdout == "6\n"
  end

  @tag :tmp_dir
  test "AOT lifecycle prints a composite result on repeated executions", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output =
      Batata.build(
        """
        defmodule Composite do
          def main(), do: {1, [2, 3], <<4, 5>>}
        end
        """,
        tmp_dir,
        ctx
      )

    binary = Path.join(tmp_dir, "run_composite")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    for _ <- 1..2 do
      {stdout, 0} = Subprocess.cmd(binary, timeout: @child_timeout)
      assert stdout == ~s|{1, [2, 3], "\x04\x05"}\n|
    end
  end

  @tag :tmp_dir
  test "runs a multi-worker AOT program in its own runtime session", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output =
      Batata.build(
        """
        defmodule Parallel do
          def main() do
            me = self()
            spawn(fn -> send(me, 7) end)

            receive do
              value when is_integer(value) -> value
            end
          end
        end
        """,
        tmp_dir,
        ctx,
        workers: 2,
        reduction_budget: 2
      )

    binary = Path.join(tmp_dir, "run_parallel")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    {stdout, 0} = Subprocess.cmd(binary, timeout: @child_timeout)
    assert stdout == "7\n"
  end

  @tag :tmp_dir
  test "preserves out-of-order messages across consecutive selective receives", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output =
      Batata.build(
        """
        defmodule FanIn do
          def main() do
            me = self()
            send(me, 20)
            send(me, 10)
            sum = Enum.reduce([1, 2, 3, 4, 5], 0, fn x, acc -> x + acc end)

            first = receive do
              10 -> 10
            end

            second = receive do
              20 -> 20
            end

            sum + first + second
          end
        end
        """,
        tmp_dir,
        ctx
      )

    binary = Path.join(tmp_dir, "run_fan_in")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    {stdout, 0} = Subprocess.cmd(binary, timeout: @child_timeout)
    assert stdout == "45\n"
  end

  @tag :tmp_dir
  test "AOT rejects unsafe scheduler multi-receive continuations", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    source = """
    defmodule UnsafeReceives do
      def main() do
        receive do
          10 -> 10
        end

        receive do
          20 -> 20
        end
      end
    end
    """

    for workers <- [1, 4] do
      assert_raise ArgumentError,
                   ~r/AOT scheduler currently supports at most one receive site/,
                   fn ->
                     Batata.build(source, tmp_dir, ctx,
                       workers: workers,
                       reduction_budget: 2
                     )
                   end
    end
  end

  @tag :tmp_dir
  test "bounded AOT execution kills and reaps a stalled child", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "stalled.c")
    binary = Path.join(tmp_dir, "run_fan_in")
    File.write!(source, "int main(void) { for (;;) {} }")

    {_, 0} =
      System.cmd("zig", ["cc", source, "-o", binary], stderr_to_stdout: true)

    error =
      assert_raise Subprocess.TimeoutError, fn ->
        Subprocess.cmd(binary, timeout: 100)
      end

    refute Subprocess.alive?(error.os_pid)
  end

  @tag :tmp_dir
  test "AOT returns its stable OOM exit code when the arena quota is exhausted", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output =
      Batata.build(
        """
        defmodule QuotaAOT do
          def main(), do: [1]
        end
        """,
        tmp_dir,
        ctx,
        memory_quota_bytes: 0
      )

    binary = Path.join(tmp_dir, "run_quota")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    {stdout, 6} = Subprocess.cmd(binary, timeout: @child_timeout)
    assert stdout == ""
  end
end
