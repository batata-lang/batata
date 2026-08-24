defmodule Batata.NativeRegistryTest do
  use ExUnit.Case, async: false

  alias Batata.Native.{Provider, ProviderNode, Registry}
  alias Batata.Stdlib.Plan

  alias Batata.TestNativeProviderNode

  test "provider protocol dispatches plans for adapter and custom nodes" do
    plan = %Plan{mfa: {Kernel, :length, 1}, class: :native_term, allocation: :none}

    assert Provider.native_plan(%ProviderNode{plan: plan, original: :node}) == plan
    assert Provider.native_plan(%TestNativeProviderNode{plan: plan, original: :node}) == plan
    assert Provider.native_plan(:anything_else) == nil
  end

  test "stdlib plan mirrors the registry class" do
    assert Batata.Stdlib.plan({Kernel, :length, 1}) ==
             %Plan{mfa: {Kernel, :length, 1}, class: :native_term, allocation: :none}

    assert Batata.Stdlib.plan({Enum, :map, 2}) ==
             %Plan{
               mfa: {Enum, :map, 2},
               class: :beamer_callback,
               allocation: :may_allocate,
               preemption: :resumable,
               reductions: :per_element
             }

    assert Batata.Stdlib.plan({File, :read!, 1}) ==
             %Plan{
               mfa: {File, :read!, 1},
               class: :native_term,
               purity: :impure,
               allocation: :may_allocate,
               preemption: :blocking,
               reductions: :external
             }

    assert Batata.Stdlib.plan({Foo, :bar, 1}) == nil
  end

  test "registry enumerates the closed-world provider set after consolidation" do
    {:ok, _beam} = Protocol.consolidate(Provider, [ProviderNode, TestNativeProviderNode])

    assert Registry.consolidated?()
    assert Enum.sort(Registry.impls()) == [Any, ProviderNode, TestNativeProviderNode]
  end
end
