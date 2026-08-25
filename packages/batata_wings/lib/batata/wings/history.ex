defmodule Batata.Wings.History do
  @moduledoc "Bounded editor history storage; transition semantics are implemented separately."

  @default_max_entries 64
  @default_max_bytes 64 * 1024 * 1024

  @enforce_keys [:past, :future, :bytes, :max_entries, :max_bytes, :evicted_generations]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          past: [term()],
          future: [term()],
          bytes: non_neg_integer(),
          max_entries: pos_integer(),
          max_bytes: pos_integer(),
          evicted_generations: [non_neg_integer()]
        }

  @spec new!(keyword()) :: t()
  def new!(options \\ []) do
    max_entries = Keyword.get(options, :max_entries, @default_max_entries)
    max_bytes = Keyword.get(options, :max_bytes, @default_max_bytes)

    unless is_integer(max_entries) and max_entries > 0 and is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError, "history limits must be positive integers"
    end

    %__MODULE__{
      past: [],
      future: [],
      bytes: 0,
      max_entries: max_entries,
      max_bytes: max_bytes,
      evicted_generations: []
    }
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = history) do
    %{
      "bytes" => history.bytes,
      "evicted_generations" => history.evicted_generations,
      "future_entries" => length(history.future),
      "max_bytes" => history.max_bytes,
      "max_entries" => history.max_entries,
      "past_entries" => length(history.past)
    }
  end
end
