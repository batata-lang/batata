defmodule Batata.Probe.DependencyFrontierTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.{DependencyFrontier, Inventory}

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
               "target_kind" => "corpus",
               "source_eligibility" => "compile_eligible",
               "blocker_categories" => %{}
             },
             %{
               "arity" => 1,
               "count" => 1,
               "function" => "iodata_to_binary",
               "module" => "Sample",
               "path" => "sample.ex",
               "target" => "IO",
               "target_kind" => "external",
               "source_eligibility" => "compile_eligible",
               "blocker_categories" => %{}
             }
           ]
  end

  @tag :tmp_dir
  test "keeps calls from modules blocked before compile attempts", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "blocked.ex"), """
    defmodule Blocked do
      import Bitwise
      def value(), do: Dependency.value()
    end

    defmodule Dependency do
      def value(), do: 1
    end
    """)

    assert tmp_dir |> Inventory.discover!() |> DependencyFrontier.collect() == [
             %{
               "arity" => 0,
               "blocker_categories" => %{"import" => 1},
               "count" => 1,
               "function" => "value",
               "module" => "Blocked",
               "path" => "blocked.ex",
               "source_eligibility" => "blocked_by_module_forms",
               "target" => "Dependency",
               "target_kind" => "corpus"
             }
           ]
  end

  @tag :tmp_dir
  test "uses accepted current-module struct schemas for source eligibility", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "struct.ex"), """
    defmodule StructCaller do
      defstruct [:value]
      def render(%__MODULE__{value: value}), do: Kernel.to_string(value)
    end
    """)

    assert [call] = tmp_dir |> Inventory.discover!() |> DependencyFrontier.collect()
    assert call["module"] == "StructCaller"
    assert call["target"] == "Kernel"
    assert call["function"] == "to_string"
    assert call["source_eligibility"] == "compile_eligible"
    assert call["blocker_categories"] == %{}
  end
end
