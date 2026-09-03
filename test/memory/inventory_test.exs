defmodule Batata.Memory.InventoryTest do
  use ExUnit.Case, async: true

  alias Batata.Memory.Inventory
  alias Batata.Native.ProviderNode
  alias Batata.Stdlib.Plan

  test "intrinsic inventory is explicit and future operations fail closed" do
    assert Inventory.intrinsic("ex.add").classification == :none
    assert Inventory.intrinsic("ex.tuple").classification == :may_allocate
    assert Inventory.intrinsic("ex.integer_mul").classification == :may_allocate
    assert Inventory.intrinsic("ex.apply").classification == :unknown
    assert Inventory.intrinsic("ex.enumerable_map_fun").classification == :unknown
    assert Inventory.intrinsic("ex.apply").provenance == "batata.memory.intrinsic.unknown"

    unknown = Inventory.intrinsic("ex.future_allocator")
    assert unknown.classification == :unknown
    assert unknown.provenance == "batata.memory.intrinsic.missing"

    assert Inventory.known_intrinsics() == Enum.sort(Inventory.known_intrinsics())
    assert length(Inventory.known_intrinsics()) == length(Enum.uniq(Inventory.known_intrinsics()))
  end

  test "stdlib plans distinguish declared allocation from missing summaries" do
    assert Inventory.stdlib({Kernel, :length, 1}).classification == :none
    assert Inventory.stdlib({Enum, :map, 2}).classification == :may_allocate

    unknown = Inventory.stdlib({Missing, :call, 1})
    assert unknown.classification == :unknown
    assert unknown.provenance == "batata.stdlib.missing"

    assert Enum.all?(Batata.Stdlib.classes(), fn {mfa, _class} ->
             Inventory.stdlib(mfa).classification in [:none, :may_allocate, :unknown]
           end)
  end

  test "provider defaults are unknown instead of accidentally pure" do
    explicit =
      %ProviderNode{
        plan: %Plan{
          mfa: {Kernel, :length, 1},
          class: :native_term,
          allocation: :none
        },
        original: :node
      }

    implicit =
      %ProviderNode{
        plan: %Plan{mfa: {Kernel, :length, 1}, class: :native_term},
        original: :node
      }

    assert Inventory.provider(explicit).classification == :none
    assert Inventory.provider(implicit).classification == :unknown
    assert Inventory.provider(:unsupported).classification == :unknown
  end

  test "external calls are unknown until a closed summary exists" do
    entry = Inventory.external("Native.decode/1")

    assert entry.kind == :external
    assert entry.classification == :unknown
    assert entry.provenance == "batata.external.summary.missing"
  end
end
