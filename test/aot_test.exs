defmodule Batata.AOTTest do
  use Batata.Case, async: true

  @moduletag timeout: 180_000

  alias Batata

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

    binary = Path.join(tmp_dir, "run_math")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    {stdout, 0} = System.cmd(binary, [])
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
      {stdout, 0} = System.cmd(binary, [])
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

    {stdout, 0} = System.cmd(binary, [])
    assert stdout == "7\n"
  end

  @tag :tmp_dir
  test "runs a fan-in AOT workload with a small growing process table", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output =
      Batata.build(
        """
        defmodule FanIn do
          def main() do
            me = self()
            spawn(fn -> send(me, 10) end)
            spawn(fn -> send(me, 20) end)
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
        ctx,
        workers: 4,
        process_cap: 2,
        reduction_budget: 2
      )

    binary = Path.join(tmp_dir, "run_fan_in")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    {stdout, 0} = System.cmd(binary, [])
    assert stdout == "45\n"
  end
end
