defmodule Batata.NativeEnumerableTest do
  use Batata.Case, async: true

  alias Batata.Native.Enumerable

  test "enumerates consolidated Enumerable implementations" do
    impls = Enumerable.impls()

    assert is_list(impls)
    assert List in impls
    assert Map in impls
    assert Range in impls
  end

  test "classifies built-in impls as internal" do
    assert Enumerable.internal?(List)
    assert Enumerable.internal?(Map)
    assert Enumerable.internal?(Range)
  end

  test "lists external impls that need BEAM or explicit rejection" do
    external = Enumerable.external()

    assert is_list(external)
    refute List in external
    refute Map in external
  end

  test "registry mirrors the runtime term-tag dispatch" do
    tags = Enumerable.registry() |> Enum.map(& &1.tag)

    assert Enum.sort(tags) == [:binary, :list, :map, :range, :tuple]
    assert Enum.sort(Enumerable.runtime_tags()) == Enum.sort(tags)
    assert Enum.all?(Enumerable.registry(), &(&1.count == :native and &1.reduce == :native))
  end
end
