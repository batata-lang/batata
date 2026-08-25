defmodule Batata.ObjC.AppKit.Application do
  @moduledoc "Compile-time DSL for the closed AppKit application slice."

  alias Batata.ObjC.AppKit.ApplicationPlan

  defmacro __using__(options) do
    quote do
      @behaviour Batata.ObjC.AppKit.Application
      Module.register_attribute(__MODULE__, :batata_objc_windows, accumulate: true)
      Module.register_attribute(__MODULE__, :batata_objc_labels, accumulate: true)
      Module.register_attribute(__MODULE__, :batata_objc_buttons, accumulate: true)
      @batata_objc_application_options unquote(options)
      @before_compile Batata.ObjC.AppKit.Application
      import Batata.ObjC.AppKit.Application,
        only: [appkit_button: 1, appkit_label: 1, appkit_window: 1]
    end
  end

  @doc false
  @callback __batata_objc_application_plan__() :: ApplicationPlan.t()

  defmacro appkit_window(options), do: accumulate(:batata_objc_windows, options)
  defmacro appkit_label(options), do: accumulate(:batata_objc_labels, options)
  defmacro appkit_button(options), do: accumulate(:batata_objc_buttons, options)

  defmacro __before_compile__(env) do
    plan =
      ApplicationPlan.new!(
        env.module,
        Module.get_attribute(env.module, :batata_objc_application_options),
        Module.get_attribute(env.module, :batata_objc_windows),
        Module.get_attribute(env.module, :batata_objc_labels),
        Module.get_attribute(env.module, :batata_objc_buttons),
        Module.definitions_in(env.module)
      )

    escaped = Macro.escape(plan)

    quote do
      @impl Batata.ObjC.AppKit.Application
      def __batata_objc_application_plan__, do: unquote(escaped)
    end
  end

  defp accumulate(attribute, options) do
    quote bind_quoted: [attribute: attribute, options: options] do
      Module.put_attribute(__MODULE__, attribute, options)
    end
  end
end
