defmodule Batata.Probe.ClosureFrontierTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.ClosureFrontier
  alias Batata.Probe.Inventory

  @tag :tmp_dir
  test "classifies dynamic apply provenance from definition bodies", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "frontier.ex"), """
    defmodule Frontier do
      def local(value) do
        fun = fn item -> item end
        fun.(value)
      end

      def caller(fun, value), do: fun.(value)
      def remote(value), do: (&Remote.run/1).(value)
      def returned(value), do: make_fun().(value)
    end
    """)

    assert [%{modules: [module]} = file] = Inventory.discover!(tmp_dir)
    assert [entry] = ClosureFrontier.collect([file])
    assert entry["path"] == "frontier.ex"
    assert entry["module"] == module.module
    assert entry["local_fn_count"] == 1

    assert Enum.map(entry["sites"], &{&1["function"], &1["arity"], &1["provenance"]}) == [
             {"local", 1, "other_external"},
             {"caller", 2, "caller_parameter"},
             {"remote", 1, "cross_module_capture"},
             {"returned", 1, "other_external"}
           ]
  end

  @tag :tmp_dir
  test "reports immediately applied anonymous functions as module local", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "local.ex"), """
    defmodule Local do
      def apply(value), do: (fn item -> item end).(value)
    end
    """)

    assert [file] = Inventory.discover!(tmp_dir)
    assert [%{"local_fn_count" => 1, "sites" => [site]}] = ClosureFrontier.collect([file])
    assert site["provenance"] == "module_local"
  end
end
