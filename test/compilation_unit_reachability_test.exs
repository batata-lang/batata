defmodule Batata.CompilationUnitReachabilityTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata.{CompilationUnit, Frontend}

  test "retains private functions at the effective arity of nested pipes", %{ctx: ctx} do
    unit =
      build_unit(
        """
        defmodule PipedPrivateReachability do
          def main(), do: 2 |> stage(3) |> finish()

          defp stage(value, amount), do: value + amount
          defp stage(), do: UnknownRuntime.unreachable()
          defp finish(value), do: value * 2
          defp unused(value), do: UnknownRuntime.unreachable(value)
        end
        """,
        {PipedPrivateReachability, :main, 0}
      )

    assert length(unit.definitions) == 3
    assert Batata.execute(unit, ctx) == 10
  end

  test "uses the effective arity for a current-module remote pipe", %{ctx: ctx} do
    unit =
      build_unit(
        """
        defmodule RemotePipedPrivateReachability do
          def main(), do: 4 |> RemotePipedPrivateReachability.add(5)

          defp add(value, amount), do: value + amount
          defp add(value), do: UnknownRuntime.unreachable(value)
        end
        """,
        {RemotePipedPrivateReachability, :main, 0}
      )

    assert length(unit.definitions) == 2
    assert Batata.execute(unit, ctx) == 9
  end

  test "keeps captures adjacent to a piped call without retaining dead definitions", %{ctx: ctx} do
    unit =
      build_unit(
        """
        defmodule CapturedPipedPrivateReachability do
          def main(), do: 3 |> apply_stage(&double/1)

          defp apply_stage(value, function), do: function.(value)
          defp double(value), do: value * 2
          defp double(), do: UnknownRuntime.unreachable()
          defp unused(), do: UnknownRuntime.unreachable()
        end
        """,
        {CapturedPipedPrivateReachability, :main, 0}
      )

    assert length(unit.definitions) == 3
    assert Batata.execute(unit, ctx) == 6
  end

  defp build_unit(source, entry) do
    source
    |> Frontend.from_source()
    |> List.wrap()
    |> CompilationUnit.build(entry: entry)
  end
end
