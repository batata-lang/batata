defmodule Batata.Probe.Jason.DecoderSubsetAOTTest do
  use Batata.Case, async: true

  @moduletag timeout: 180_000

  alias Batata
  alias Batata.Test.JasonDecoderSubset

  @tag :tmp_dir
  test "runs the recursive value/rest cursor parser through AOT", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    output = Batata.build(JasonDecoderSubset.cursor_source("[1,[2,3],null]"), tmp_dir, ctx)
    binary = Path.join(tmp_dir, "run_jason_decoder_subset")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    {stdout, 0} = System.cmd(binary, [])
    assert stdout == "[1, [2, 3], nil]\n"
  end
end
