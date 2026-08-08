defmodule Batata.Native.Registry do
  @moduledoc """
  Introspection helpers for native replacement provider implementations.

  When the `Batata.Native.Provider` protocol is consolidated, `impls/0`
  returns the closed-world implementation list; otherwise it reports
  `not_consolidated` so callers can fall back to the built-in stdlib table.
  """

  alias Batata.Native.Provider

  @doc """
  Returns known provider implementation modules when the protocol is
  consolidated, or `[]` otherwise.
  """
  @spec impls() :: [module()]
  def impls do
    case Provider.__protocol__(:impls) do
      {:consolidated, impls} -> impls
      :not_consolidated -> []
    end
  end

  @doc "Returns whether the native provider protocol has been consolidated."
  @spec consolidated?() :: boolean()
  def consolidated? do
    Provider.__protocol__(:consolidated?)
  end
end
