defmodule Batata.ObjC do
  @moduledoc """
  Compile-time, fail-closed Objective-C bindings for Batata.

  The initial surface is a reviewed Foundation/AppKit allowlist. It does not
  expose arbitrary selector dispatch or an untyped object escape hatch.
  """

  alias Batata.ObjC.{BindingPlan, Metadata}

  @doc "Returns the pinned AppKit binding plan for a Batata module."
  @spec appkit_plan(module(), keyword()) :: BindingPlan.t()
  def appkit_plan(module, options \\ []) when is_atom(module) do
    BindingPlan.new!(module, Metadata.load!(), options)
  end

  @doc "Returns the canonical binding JSON."
  @spec canonical_json(BindingPlan.t()) :: String.t()
  def canonical_json(plan), do: BindingPlan.canonical_json(plan)

  @doc "Returns the binding-plan SHA-256 digest."
  @spec digest(BindingPlan.t()) :: String.t()
  def digest(plan), do: BindingPlan.digest(plan)
end
