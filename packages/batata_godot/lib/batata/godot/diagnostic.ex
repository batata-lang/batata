defmodule Batata.Godot.Diagnostic do
  @moduledoc "A stable, machine-readable failure emitted while building a binding plan."

  @enforce_keys [:code, :message]
  defexception [:code, :message, context: %{}, actions: []]

  @type action :: %{required(:command) => String.t(), optional(atom()) => term()}
  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          context: map(),
          actions: [action()]
        }

  @impl Exception
  def exception(options) do
    code = Keyword.fetch!(options, :code)
    message = Keyword.fetch!(options, :message)
    context = Keyword.get(options, :context, %{})
    actions = Keyword.get(options, :actions, [])

    unless is_binary(code) and String.starts_with?(code, "E_GODOT_") do
      raise ArgumentError, "Godot diagnostic code must start with E_GODOT_"
    end

    unless is_binary(message) and is_map(context) and is_list(actions) do
      raise ArgumentError, "invalid Godot diagnostic fields"
    end

    %__MODULE__{code: code, message: message, context: context, actions: actions}
  end

  @impl Exception
  def message(%__MODULE__{} = diagnostic), do: diagnostic |> to_map() |> JSON.encode!()

  @doc "Converts the exception to a JSON-ready map with stable string keys."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diagnostic) do
    %{
      "actions" => Enum.map(diagnostic.actions, &stringify_keys/1),
      "code" => diagnostic.code,
      "context" => stringify_keys(diagnostic.context),
      "message" => diagnostic.message,
      "recoverable" => diagnostic.actions != []
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_keys(value), do: value
end
