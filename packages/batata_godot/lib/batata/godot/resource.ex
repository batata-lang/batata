defmodule Batata.Godot.Resource do
  @moduledoc false

  alias Batata.Godot.BindingPlan

  @doc false
  @spec gdextension_source(BindingPlan.t(), String.t()) :: String.t()
  def gdextension_source(%BindingPlan{} = plan, library_name) when is_binary(library_name) do
    """
    [configuration]

    entry_symbol = "#{plan.entry_symbol}"
    compatibility_minimum = "#{plan.compatibility_minimum}"
    reloadable = #{plan.reloadable}

    [libraries]

    macos.debug.arm64 = "res://bin/#{library_name}"
    """
  end
end
