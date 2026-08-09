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

  test "compile plans classify internal as runtime_tag and external as unsupported" do
    assert Enumerable.compile_plan(List) == %{
             count: :runtime_tag,
             reduce: :runtime_tag,
             to_list: :runtime_tag,
             reason: nil
           }

    plan = Enumerable.compile_plan(Stream)
    assert plan.count == :unsupported
    assert plan.reduce == :unsupported
    assert plan.to_list == :unsupported
    assert plan.reason =~ "outside the slice"
  end

  test "slice-native external impls (MapSet/HashSet) get runtime_tag plans" do
    assert Enumerable.compile_plan(MapSet).count == :runtime_tag
    assert Enumerable.compile_plan(MapSet).reduce == :runtime_tag
    assert Enumerable.compile_plan(HashSet).count == :runtime_tag
  end

  test "plans cover every consolidated impl with a reason when unsupported" do
    plans = Enumerable.plans()

    assert length(plans) == length(Enumerable.impls())

    Enum.each(plans, fn {impl, plan} ->
      if Enumerable.compile_plan(impl).count == :runtime_tag do
        assert plan.count == :runtime_tag
      else
        assert plan.count == :unsupported
        assert plan.reason != nil
      end
    end)
  end

  test "register_native maps external impls to runtime callback slots" do
    assert Enumerable.register_native(List, %{count: 0, reduce: 1}) == nil

    assert Enumerable.register_native(MapSet, %{count: 0, reduce: 1}) ==
             {:ok, [{0, :count}, {1, :reduce}]}
  end
end
