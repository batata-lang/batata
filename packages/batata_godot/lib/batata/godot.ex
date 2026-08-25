defmodule Batata.Godot do
  @moduledoc """
  Compile-time declarations for Batata Godot GDExtension bindings.

  The package produces a validated, canonical binding plan and can build the
  first loadable raw GDExtension boundary. Class registration and method
  trampolines remain fail-closed until their ABI and ownership path exists.
  """

  alias Batata.Godot.{BindingPlan, Build, Diagnostic}

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

  @doc "Builds a macOS arm64 GDExtension from Batata source and a binding plan."
  @spec build(
          String.t(),
          module() | BindingPlan.t(),
          Path.t(),
          Beaver.MLIR.Context.t(),
          keyword()
        ) ::
          Build.output()
  def build(source, extension, output_dir, ctx, opts \\ []) do
    Build.build(source, extension, output_dir, ctx, opts)
  end

  @doc "Replays a built extension through Godot 4.6.2 headless loading."
  @spec smoke_load!(Path.t(), Path.t() | nil) :: :ok
  def smoke_load!(output_dir, godot \\ nil), do: Build.smoke_load!(output_dir, godot)

  @doc "Replays a built extension through pinned Godot headless editor mode."
  @spec editor_smoke_load!(Path.t(), Path.t() | nil, map() | [map()] | nil) :: :ok
  def editor_smoke_load!(output_dir, godot \\ nil, invocation \\ nil),
    do: Build.editor_smoke_load!(output_dir, godot, invocation)
end
