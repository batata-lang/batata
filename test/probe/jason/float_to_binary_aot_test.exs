defmodule Batata.Probe.Jason.FloatToBinaryAOTTest do
  use Batata.Case, async: true

  @moduletag timeout: 180_000

  alias Batata

  @tag :tmp_dir
  test "formats JSON float boundaries through AOT", %{ctx: ctx, tmp_dir: tmp_dir} do
    values = [
      0.0,
      -0.0,
      0.1,
      1000.0,
      1230.0,
      0.00001,
      5.0e-324,
      1.797_693_134_862_315_7e308
    ]

    source = """
    defmodule JasonFloatFormatAOT do
      def format(value), do: :erlang.float_to_binary(value, [:short])

      def main() do
        [
          format(0.0),
          format(-0.0),
          format(0.1),
          format(1000.0),
          format(1230.0),
          format(0.00001),
          format(5.0e-324),
          format(1.7976931348623157e308)
        ]
      end
    end
    """

    output = Batata.build(source, tmp_dir, ctx)
    binary = Path.join(tmp_dir, "run_jason_float_format")

    {_, 0} =
      System.cmd(
        "zig",
        ["cc", output.driver, output.archive, output.runtime_lib, "-lc", "-o", binary],
        stderr_to_stdout: true
      )

    expected = values |> Enum.map(&:erlang.float_to_binary(&1, [:short])) |> inspect()
    {stdout, 0} = System.cmd(binary, [])
    assert stdout == expected <> "\n"
  end
end
