defmodule Batata.Wings.Diagnostic do
  @moduledoc "A machine-readable failure emitted by the Wings geometry kernel."

  alias Batata.Wings.CanonicalJSON

  defexception [:code, :message, context: %{}, actions: [], recoverable: false]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          context: map(),
          actions: [map()],
          recoverable: boolean()
        }

  @spec new!(String.t(), String.t(), map(), [map()], boolean()) :: t()
  def new!(code, message, context \\ %{}, actions \\ [], recoverable \\ false) do
    unless is_binary(code) and String.starts_with?(code, "E_WINGS_") do
      raise ArgumentError, "Wings diagnostic code must start with E_WINGS_"
    end

    %__MODULE__{
      code: code,
      message: message,
      context: context,
      actions: actions,
      recoverable: recoverable
    }
  end

  @impl Exception
  def message(%__MODULE__{} = diagnostic) do
    diagnostic
    |> to_map()
    |> CanonicalJSON.encode!()
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diagnostic) do
    %{
      "actions" => diagnostic.actions,
      "code" => diagnostic.code,
      "context" => diagnostic.context,
      "message" => diagnostic.message,
      "recoverable" => diagnostic.recoverable
    }
  end
end
