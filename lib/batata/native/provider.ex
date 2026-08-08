defprotocol Batata.Native.Provider do
  @moduledoc """
  Protocol extension point for native replacement planning (M3/M5, tsai/beaver#27).

  `Batata.Stdlib` covers built-in Kernel/Enum/String/Base replacement
  candidates. This protocol lets project-local IR nodes provide the same kind
  of replacement plan through normal `defimpl` dispatch, so protocol
  consolidation can expose a closed-world provider set at compile time.
  """

  @fallback_to_any true

  @doc """
  Returns a native replacement plan for `node`, or `nil` when unsupported.
  """
  def native_plan(node)
end

defimpl Batata.Native.Provider, for: Any do
  def native_plan(_node), do: nil
end

defmodule Batata.Native.ProviderNode do
  @moduledoc """
  Minimal adapter for project-provided native replacement plans.

  This gives provider-based replacement a concrete, consolidatable
  implementation; richer domain-specific nodes can add their own
  `defimpl Batata.Native.Provider` later.
  """

  @enforce_keys [:plan, :original]
  defstruct [:plan, :original]
end

defimpl Batata.Native.Provider, for: Batata.Native.ProviderNode do
  def native_plan(%{plan: %Batata.Stdlib.Plan{} = plan}), do: plan
  def native_plan(_node), do: nil
end
