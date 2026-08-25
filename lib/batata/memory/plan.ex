defmodule Batata.Memory.Plan do
  @moduledoc "Canonical collection of memory effects and residual obligations."

  alias Batata.Memory
  alias Batata.Memory.{Effect, Obligation}

  @enforce_keys [:policy, :source_hash, :compiler_version, :dependency_lock]
  defstruct [
    :policy,
    :source_hash,
    :compiler_version,
    :dependency_lock,
    effects: [],
    obligations: []
  ]

  @type t :: %__MODULE__{
          policy: :disabled | :report | :strict,
          source_hash: String.t(),
          compiler_version: String.t(),
          dependency_lock: String.t(),
          effects: [Effect.t()],
          obligations: [Obligation.t()]
        }

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    plan = struct!(__MODULE__, opts)

    unless plan.policy in [:disabled, :report, :strict] and is_binary(plan.source_hash) and
             is_binary(plan.compiler_version) and is_binary(plan.dependency_lock) and
             Enum.all?(plan.effects, &is_struct(&1, Effect)) and
             Enum.all?(plan.obligations, &is_struct(&1, Obligation)) do
      raise ArgumentError, "invalid memory plan fields"
    end

    plan
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = plan) do
    %{
      "compiler_version" => plan.compiler_version,
      "dependency_lock" => plan.dependency_lock,
      "effects" =>
        plan.effects |> Enum.map(&Effect.to_map/1) |> Enum.sort_by(&get_in(&1, ["site", "id"])),
      "obligations" =>
        plan.obligations
        |> Enum.map(&Obligation.to_map/1)
        |> Enum.sort_by(&{get_in(&1, ["site", "id"]), &1["kind"]}),
      "policy" => Atom.to_string(plan.policy),
      "schema" => "batata-memory-plan/1",
      "source_hash" => plan.source_hash
    }
  end

  @spec canonical_json(t()) :: String.t()
  def canonical_json(%__MODULE__{} = plan), do: plan |> canonical_map() |> Memory.canonical_json()

  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = plan), do: plan |> canonical_map() |> Memory.digest()
end
