defmodule Batata.Memory.Receipt do
  @moduledoc "A bounded-memory proof receipt; inventory-only M0 plans cannot create one."

  alias Batata.Memory

  @enforce_keys [
    :source_hash,
    :compiler_version,
    :dependency_lock,
    :memory_plan_hash,
    :maximum_memory
  ]
  defstruct [
    :source_hash,
    :compiler_version,
    :dependency_lock,
    :memory_plan_hash,
    :maximum_memory,
    assurance: :bounded,
    runtime_guards: [],
    unproven_obligations: []
  ]

  @type t :: %__MODULE__{}

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    receipt = struct!(__MODULE__, opts)

    unless receipt.assurance == :bounded do
      raise ArgumentError, "batata-memory-receipt/1 requires :bounded assurance"
    end

    unless receipt.unproven_obligations == [] do
      raise ArgumentError, "memory receipt requires zero unproven obligations"
    end

    unless valid_non_negative_integer_string?(receipt.maximum_memory) do
      raise ArgumentError, "memory receipt :maximum_memory must be a non-negative integer string"
    end

    receipt
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = receipt) do
    %{
      "assurance" => Atom.to_string(receipt.assurance),
      "compiler_version" => receipt.compiler_version,
      "dependency_lock" => receipt.dependency_lock,
      "maximum_memory" => receipt.maximum_memory,
      "memory_plan_hash" => receipt.memory_plan_hash,
      "runtime_guards" => receipt.runtime_guards,
      "schema" => "batata-memory-receipt/1",
      "source_hash" => receipt.source_hash,
      "unproven_obligations" => receipt.unproven_obligations
    }
  end

  @spec canonical_json(t()) :: String.t()
  def canonical_json(%__MODULE__{} = receipt),
    do: receipt |> canonical_map() |> Memory.canonical_json()

  defp valid_non_negative_integer_string?(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> Integer.to_string(integer) == value
      _ -> false
    end
  end

  defp valid_non_negative_integer_string?(_value), do: false
end
