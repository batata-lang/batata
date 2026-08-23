defmodule Batata.Godot do
  @moduledoc """
  Compile-time declarations for generated Godot GDExtension bindings.

  The initial package produces a validated, canonical binding plan. Native
  adapter generation and shared-library linking are deliberately later
  stages, so an unsupported declaration fails before native compilation.
  """

  alias Batata.Godot.{BindingPlan, Diagnostic}

  @doc false
  @callback __batata_godot_plan__() :: BindingPlan.t()

  @doc "Returns the binding plan embedded in an extension module."
  @spec binding_plan(module()) :: BindingPlan.t()
  def binding_plan(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__batata_godot_plan__, 0) do
      module.__batata_godot_plan__()
    else
      raise Diagnostic,
        code: "E_GODOT_BINDING_PLAN_MISSING",
        message: "module does not expose a Batata Godot binding plan",
        context: %{module: inspect(module)},
        actions: [%{command: "use Batata.Godot.Extension in the extension module"}]
    end
  end

  @doc "Returns the canonical JSON representation embedded by the extension."
  @spec canonical_json(module()) :: String.t()
  def canonical_json(module), do: module |> binding_plan() |> BindingPlan.canonical_json()

  @doc "Returns the SHA-256 digest of the canonical binding plan."
  @spec digest(module()) :: String.t()
  def digest(module), do: module |> binding_plan() |> BindingPlan.digest()
end
