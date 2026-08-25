defmodule Batata.Memory.DiagnosticError do
  @moduledoc "Stable machine-readable failure from proof-carrying memory analysis."

  alias Batata.Memory.{CanonicalJSON, Obligation, Site}

  @enforce_keys [:code, :message, :policy, :site, :obstruction]
  defexception [:code, :message, :policy, :site, :obstruction, strategies: []]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          policy: :report | :strict,
          site: Site.t(),
          obstruction: Obligation.t() | map(),
          strategies: [map()]
        }

  @impl Exception
  def exception(opts) do
    diagnostic = struct!(__MODULE__, opts)

    unless is_binary(diagnostic.code) and String.starts_with?(diagnostic.code, "E_MEMORY_") do
      raise ArgumentError, "memory diagnostic code must start with E_MEMORY_"
    end

    unless is_binary(diagnostic.message) and diagnostic.policy in [:report, :strict] and
             is_struct(diagnostic.site, Site) and is_list(diagnostic.strategies) do
      raise ArgumentError, "invalid memory diagnostic fields"
    end

    diagnostic
  end

  @impl Exception
  def message(%__MODULE__{} = diagnostic), do: diagnostic |> to_map() |> CanonicalJSON.encode!()

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = diagnostic) do
    %{
      "code" => diagnostic.code,
      "message" => diagnostic.message,
      "obstruction" => obstruction_map(diagnostic.obstruction),
      "policy" => Atom.to_string(diagnostic.policy),
      "recoverable" => diagnostic.strategies != [],
      "schema" => "batata-memory/1",
      "site" => Site.to_map(diagnostic.site),
      "strategies" => diagnostic.strategies
    }
  end

  defp obstruction_map(%Obligation{} = obligation), do: Obligation.to_map(obligation)
  defp obstruction_map(obstruction) when is_map(obstruction), do: obstruction

  defp obstruction_map(obstruction) do
    raise ArgumentError,
          "memory diagnostic obstruction must be an obligation or map, got: #{inspect(obstruction)}"
  end
end
