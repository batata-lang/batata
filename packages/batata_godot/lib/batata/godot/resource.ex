defmodule Batata.Godot.Resource do
  @moduledoc false

  alias Batata.Godot.BindingPlan

  @doc false
  @spec gdextension_source(BindingPlan.t(), %{String.t() => String.t()}) :: String.t()
  def gdextension_source(%BindingPlan{} = plan, libraries) when is_map(libraries) do
    library_lines =
      libraries
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {feature, library_name} ->
        ~s|#{feature} = "res://bin/#{library_name}"|
      end)

    """
    [configuration]

    entry_symbol = "#{plan.entry_symbol}"
    compatibility_minimum = "#{plan.compatibility_minimum}"
    reloadable = #{plan.reloadable}

    [libraries]

    #{library_lines}
    """
  end
end
