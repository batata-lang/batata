defmodule Batata.Frontend.MultiModuleTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend
  alias Beaver.MLIR.Context

  test "normalizes multiple modules in a single source block and shares schemas" do
    source = """
    defmodule Point do
      defstruct x: 0, y: 0
    end

    defmodule Graph do
      def origin(), do: %Point{x: 0, y: 0}
      def is_origin?(%Point{x: 0, y: 0}), do: true
      def is_origin?(%Point{}), do: false
    end
    """

    modules = Frontend.from_source(source)
    assert is_list(modules)
    assert length(modules) == 2

    [point_mod, graph_mod] = modules
    assert point_mod.name == Point
    assert graph_mod.name == Graph

    assert Map.has_key?(graph_mod.struct_schemas, Point)
    assert graph_mod.unsupported == []
  end

  test "shares schemas across sources and executes the consumer snapshot" do
    source_point = """
    defmodule Point do
      defstruct x: 0, y: 0
    end
    """

    source_graph = """
    defmodule Graph do
      def make(x, y), do: %Point{x: x, y: y}

      def sum(%Point{x: x, y: y}) when is_integer(x) and is_integer(y) do
        x + y
      end

      def main() do
        p = make(15, 25)
        sum(p)
      end
    end
    """

    [point_mod, graph_mod] = Frontend.from_sources([source_point, source_graph])

    assert graph_mod.struct_schemas[Point] == point_mod.struct_schema
    assert 40 == Batata.execute(graph_mod, Context.create())
  end

  test "materializes literal atoms when executing a module snapshot" do
    snapshot =
      Frontend.from_source("""
      defmodule SnapshotAtom do
        def main(), do: :from_snapshot
      end
      """)

    assert :from_snapshot == Batata.execute(snapshot, Context.create())
  end

  test "applies the parallel receive-site guard to module snapshots" do
    snapshot =
      Frontend.from_source("""
      defmodule SnapshotReceives do
        def first() do
          receive do
            message -> message
          end
        end

        def second() do
          receive do
            message -> message
          end
        end

        def main(), do: 0
      end
      """)

    assert_raise ArgumentError,
                 ~r/parallel workers currently support at most one receive site/,
                 fn -> Batata.compile(snapshot, Context.create(), workers: 2) end
  end
end
