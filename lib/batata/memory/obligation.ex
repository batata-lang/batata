defmodule Batata.Memory.Obligation do
  @moduledoc "One residual proof obligation emitted by memory analysis."

  alias Batata.Memory.Site

  @enforce_keys [:kind, :site, :missing_fact]
  defstruct [:kind, :site, :missing_fact, context: %{}, strategies: []]

  @type t :: %__MODULE__{
          kind: String.t() | atom(),
          site: Site.t(),
          missing_fact: String.t(),
          context: map(),
          strategies: [map()]
        }

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    obligation = struct!(__MODULE__, opts)

    unless (is_atom(obligation.kind) or is_binary(obligation.kind)) and
             is_struct(obligation.site, Site) and is_binary(obligation.missing_fact) and
             is_map(obligation.context) and is_list(obligation.strategies) do
      raise ArgumentError, "invalid memory obligation fields"
    end

    obligation
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = obligation) do
    %{
      "context" => obligation.context,
      "kind" => to_string(obligation.kind),
      "missing_fact" => obligation.missing_fact,
      "site" => Site.to_map(obligation.site),
      "strategies" => obligation.strategies
    }
  end
end
