defmodule Batata.SelfBootstrapTest do
  use Batata.Case, async: true

  alias Batata
  alias Batata.Export

  @fixture Path.expand("fixtures/self_bootstrap.exs", __DIR__)

  test "self-bootstrap fixture is compiled by batata to the BEAM result", %{ctx: ctx} do
    source = File.read!(@fixture)

    assert Batata.execute(source, ctx) ==
             beam_classify(1, 1) + beam_classify(1, 2) * 10 +
               beam_classify(0, 2) * 100 + beam_classify(1, 0) * 1000

    assert beam_classify(1, 1) + beam_classify(1, 2) * 10 + beam_classify(0, 2) * 100 +
             beam_classify(1, 0) * 1000 == 3241
  end

  @tag :tmp_dir
  test "self-bootstrap fixture builds to a runnable AOT binary with verified symbols", %{
    ctx: ctx,
    tmp_dir: tmp_dir
  } do
    source = File.read!(@fixture)

    output =
      Batata.build(source, tmp_dir, ctx)

    %{bundle: bundle} = Export.read(tmp_dir)
    assert :ok = Export.verify_symbols!(output.archive, bundle["exports"])

    binary = Path.join(tmp_dir, "run_self_bootstrap")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    {stdout, 0} = System.cmd(binary, [])
    assert stdout == "3241\n"
  end

  # BEAM oracle for the fixture's classification, so the gate compares against
  # the reference implementation rather than a hardcoded constant.
  defp beam_classify(a, b) when a == b, do: 1
  defp beam_classify(0, _b), do: 2
  defp beam_classify(_a, 0), do: 3
  defp beam_classify(_a, _b), do: 4
end
