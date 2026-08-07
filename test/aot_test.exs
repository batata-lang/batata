defmodule Batata.AOTTest do
  use Batata.Case, async: true

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
      System.cmd("cc", [output.driver, output.archive, "-o", binary], stderr_to_stdout: true)

    {stdout, 0} = System.cmd(binary, [])
    assert stdout == "6\n"
  end
end
