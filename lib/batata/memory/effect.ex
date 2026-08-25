defmodule Batata.Memory.Effect do
  @moduledoc "Allocation and lifetime facts attached to one stable memory site."

  alias Batata.Memory.{Bound, Site}

  @classifications [:none, :may_allocate, :exact, :bounded, :parametric, :guarded, :unknown]

  @enforce_keys [:site, :classification, :provenance]
  defstruct [
    :site,
    :classification,
    :provenance,
    :size,
    :region,
    :escape,
    :lifetime,
    :failure,
    :callee,
    context: %{}
  ]

  @type classification ::
          :none | :may_allocate | :exact | :bounded | :parametric | :guarded | :unknown
  @type t :: %__MODULE__{
          site: Site.t(),
          classification: classification(),
          provenance: String.t() | atom(),
          size: term() | nil,
          region: String.t() | atom() | nil,
          escape: String.t() | atom() | nil,
          lifetime: term() | nil,
          failure: String.t() | atom() | nil,
          callee: String.t() | nil,
          context: map()
        }

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    effect = struct!(__MODULE__, opts)

    unless effect.classification in @classifications do
      raise ArgumentError,
            "invalid memory effect classification: #{inspect(effect.classification)}"
    end

    unless is_struct(effect.site, Site) do
      raise ArgumentError, "memory effect :site must be a Batata.Memory.Site"
    end

    unless (is_atom(effect.provenance) or is_binary(effect.provenance)) and
             effect.provenance not in [nil, ""] do
      raise ArgumentError, "memory effect :provenance must be a non-empty atom or string"
    end

    unless is_map(effect.context) do
      raise ArgumentError, "memory effect :context must be a map"
    end

    effect
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = effect) do
    %{
      "callee" => effect.callee,
      "classification" => Atom.to_string(effect.classification),
      "context" => effect.context,
      "escape" => stringify(effect.escape),
      "failure" => stringify(effect.failure),
      "lifetime" => effect.lifetime,
      "provenance" => stringify(effect.provenance),
      "region" => stringify(effect.region),
      "site" => Site.to_map(effect.site),
      "size" => encode_size(effect.size)
    }
  end

  defp encode_size(%Bound{} = bound), do: Bound.canonical_map(bound)
  defp encode_size(size), do: size

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
