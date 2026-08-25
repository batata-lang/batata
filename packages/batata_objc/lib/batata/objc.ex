defmodule Batata.ObjC do
  @moduledoc """
  Compile-time, fail-closed Objective-C bindings for Batata.

  The initial surface is a reviewed Foundation/AppKit allowlist. It does not
  expose arbitrary selector dispatch or an untyped object escape hatch.
  """

  alias Batata.ObjC.AppKit.ApplicationPlan
  alias Batata.ObjC.{BindingPlan, Build, Diagnostic, Metadata}

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

  @doc "Builds and receipts the fixed Objective-C runtime adapter."
  @spec build_runtime(BindingPlan.t(), Path.t(), keyword()) :: Build.output()
  def build_runtime(plan, output_dir, options \\ []),
    do: Build.build_runtime(plan, output_dir, options)

  @doc "Returns the compile-time AppKit application descriptor."
  @spec application_plan(module()) :: ApplicationPlan.t()
  def application_plan(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and
         function_exported?(module, :__batata_objc_application_plan__, 0) do
      module.__batata_objc_application_plan__()
    else
      raise Diagnostic,
        code: "E_OBJC_APPLICATION_PLAN_INVALID",
        message: "module does not expose an AppKit application plan",
        context: %{module: inspect(module)},
        actions: [%{command: "use Batata.ObjC.AppKit.Application"}]
    end
  end

  @doc "Compiles Batata callbacks into a runnable, receipted AppKit bundle."
  @spec build_app(
          String.t(),
          module() | ApplicationPlan.t(),
          Path.t(),
          Beaver.MLIR.Context.t(),
          keyword()
        ) :: map()
  def build_app(source, application, output_dir, ctx, options \\ []) do
    application = if is_atom(application), do: application_plan(application), else: application
    Build.build_app(source, application, output_dir, ctx, options)
  end
end
