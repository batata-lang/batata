defmodule Batata.Probe.Jason.DependencyFrontierTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.{DependencyFrontier, Inventory}

  @tag :tmp_dir
  test "separates corpus and external calls for compile-eligible modules", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "sample.ex"), """
    defmodule Sample do
      def parse(input, opts \\\\ []) do
        IO.iodata_to_binary(Dependency.parse(input, opts))
      end
    end

    defmodule Dependency do
      def parse(input, _opts), do: input
    end
    """)

    frontier = tmp_dir |> Inventory.discover!() |> DependencyFrontier.collect()

    assert frontier == [
             %{
               "arity" => 2,
               "count" => 1,
               "function" => "parse",
               "module" => "Sample",
               "path" => "sample.ex",
               "target" => "Dependency",
               "target_kind" => "corpus"
             },
             %{
               "arity" => 1,
               "count" => 1,
               "function" => "iodata_to_binary",
               "module" => "Sample",
               "path" => "sample.ex",
               "target" => "IO",
               "target_kind" => "external"
             }
           ]
  end

  @tag :tmp_dir
  test "ignores modules blocked before compile attempts", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "blocked.ex"), """
    defmodule Blocked do
      import Bitwise
      def value(), do: Dependency.value()
    end
    """)

    assert tmp_dir |> Inventory.discover!() |> DependencyFrontier.collect() == []
  end
end
