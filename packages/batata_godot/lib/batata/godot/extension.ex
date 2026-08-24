defmodule Batata.Godot.Extension do
  @moduledoc """
  Declares one compile-time GDExtension binding surface.

  The declaration is converted into a validated `Batata.Godot.BindingPlan`
  before the extension module finishes compiling. This first schema permits
  one Godot class and scalar method signatures.
  """

  alias Batata.Godot.BindingPlan

  defmacro __using__(options \\ []) do
    quote do
      @behaviour Batata.Godot
      import Batata.Godot.Extension,
        only: [
          godot_class: 1,
          godot_class: 2,
          godot_method: 2,
          godot_property: 2,
          godot_signal: 1,
          godot_signal: 2,
          godot_virtual: 1
        ]

      Module.register_attribute(__MODULE__, :batata_godot_extension_options, persist: false)
      Module.register_attribute(__MODULE__, :batata_godot_classes, accumulate: true)
      Module.register_attribute(__MODULE__, :batata_godot_methods, accumulate: true)
      Module.register_attribute(__MODULE__, :batata_godot_properties, accumulate: true)
      Module.register_attribute(__MODULE__, :batata_godot_signals, accumulate: true)
      Module.register_attribute(__MODULE__, :batata_godot_virtuals, accumulate: true)

      @batata_godot_extension_options unquote(options)
      @before_compile Batata.Godot.Extension
    end
  end

  defmacro godot_class(name, options \\ []) do
    quote do
      @batata_godot_classes {unquote(name), unquote(options)}
    end
  end

  defmacro godot_method(name, options) do
    quote do
      @batata_godot_methods {unquote(name), unquote(options)}
    end
  end

  defmacro godot_property(name, options) do
    quote do
      @batata_godot_properties {unquote(name), unquote(options)}
    end
  end

  defmacro godot_signal(name, options \\ []) do
    quote do
      @batata_godot_signals {unquote(name), unquote(options)}
    end
  end

  defmacro godot_virtual(name) do
    quote do
      @batata_godot_virtuals unquote(name)
    end
  end

  defmacro __before_compile__(environment) do
    module = environment.module
    extension_options = Module.get_attribute(module, :batata_godot_extension_options) || []
    classes = module |> Module.get_attribute(:batata_godot_classes) |> Enum.reverse()
    methods = module |> Module.get_attribute(:batata_godot_methods) |> Enum.reverse()
    properties = module |> Module.get_attribute(:batata_godot_properties) |> Enum.reverse()
    signals = module |> Module.get_attribute(:batata_godot_signals) |> Enum.reverse()
    virtuals = module |> Module.get_attribute(:batata_godot_virtuals) |> Enum.reverse()
    definitions = Module.definitions_in(module, :def)

    plan =
      BindingPlan.new!(
        module,
        extension_options,
        classes,
        methods,
        properties,
        signals,
        virtuals,
        definitions
      )

    quote do
      @doc false
      @impl Batata.Godot
      def __batata_godot_plan__, do: unquote(Macro.escape(plan))
    end
  end
end
