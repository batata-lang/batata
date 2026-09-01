defmodule Batata.ScalarBoundaryTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata

  test "contains an invalid scalar raise inside a subprocess" do
    executable = System.find_executable("elixir")
    fixture = Path.expand("support/scalar_boundary_probe.exs", __DIR__)

    code_paths =
      :code.get_path()
      |> Enum.flat_map(fn path -> ["-pa", List.to_string(path)] end)

    {output, status} =
      System.cmd(executable, ["--erl", "+S 1:1"] ++ code_paths ++ [fixture],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "caught ArgumentError"
  end

  test "materializes invalid scalar arguments as exceptions", %{ctx: ctx} do
    source = """
    defmodule InvalidScalarBoundary do
      def maximum(left, right), do: Kernel.max(left, right)
      def minimum(left, right), do: Kernel.min(left, right)
      def magnitude(value), do: Kernel.abs(value)

      def main() do
        {maximum("a", "b"), minimum(:a, :b), magnitude("c")}
      end
    end
    """

    assert_raise ArgumentError, fn -> Batata.execute(source, ctx) end
  end

  test "preserves valid signed scalar calls", %{ctx: ctx} do
    source = """
    defmodule ValidScalarBoundary do
      def maximum(left, right), do: Kernel.max(left, right)
      def minimum(left, right), do: Kernel.min(left, right)
      def magnitude(value), do: Kernel.abs(value)
      def main(), do: {maximum(-7, 3), minimum(-7, 3), magnitude(-7)}
    end
    """

    assert Batata.execute(source, ctx) == {3, -7, 7}
  end
end
