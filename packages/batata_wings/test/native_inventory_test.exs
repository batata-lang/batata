defmodule Batata.Wings.Native.InventoryTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.Native.Inventory

  test "inventory binds every native candidate to path, functions, and source digest" do
    inventory = Inventory.source_inventory()

    assert inventory["schema_version"] == 1
    assert byte_size(inventory["source_set_sha256"]) == 64
    assert length(inventory["entries"]) == 10

    assert Enum.any?(inventory["entries"], fn entry ->
             entry["module"] == "Batata.Wings.Topology.Build" and
               entry["source"] ==
                 "packages/batata_wings/lib/batata/wings/topology/build.ex" and
               byte_size(entry["source_sha256"]) == 64 and
               %{"arity" => 1, "name" => "build!", "visibility" => "public"} in entry["functions"]
           end)

    assert Enum.all?(inventory["entries"], fn entry ->
             entry["functions"] != [] and byte_size(entry["source_sha256"]) == 64
           end)
  end
end
