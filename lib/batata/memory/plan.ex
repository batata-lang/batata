defmodule Batata.Memory.Plan do
  @moduledoc "Canonical collection of memory effects and residual obligations."

  alias Batata.Memory
  alias Batata.Memory.{Bound, Effect, Obligation, Region}

  @enforce_keys [:policy, :source_hash, :compiler_version, :dependency_lock]
  defstruct [
    :policy,
    :source_hash,
    :compiler_version,
    :dependency_lock,
    :maximum_memory,
    effects: [],
    obligations: [],
    preconditions: [],
    regions: [],
    reset_points: [],
    runtime_guards: []
  ]

  @type t :: %__MODULE__{
          policy: :disabled | :report | :strict,
          source_hash: String.t(),
          compiler_version: String.t(),
          dependency_lock: String.t(),
          maximum_memory: Bound.t() | nil,
          effects: [Effect.t()],
          obligations: [Obligation.t()],
          preconditions: [map()],
          regions: [Region.t()],
          reset_points: [map()],
          runtime_guards: [map()]
        }

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    plan = struct!(__MODULE__, opts)

    if valid_header?(plan) and valid_analysis?(plan) and valid_regions?(plan),
      do: plan,
      else: raise(ArgumentError, "invalid memory plan fields")
  end

  defp valid_header?(plan) do
    plan.policy in [:disabled, :report, :strict] and is_binary(plan.source_hash) and
      is_binary(plan.compiler_version) and is_binary(plan.dependency_lock)
  end

  defp valid_analysis?(plan) do
    (is_nil(plan.maximum_memory) or is_struct(plan.maximum_memory, Bound)) and
      Enum.all?(plan.effects, &is_struct(&1, Effect)) and
      Enum.all?(plan.obligations, &is_struct(&1, Obligation)) and is_list(plan.preconditions)
  end

  defp valid_regions?(plan) do
    Enum.all?(plan.regions, &is_struct(&1, Region)) and is_list(plan.reset_points) and
      is_list(plan.runtime_guards)
  end

  @spec canonical_map(t()) :: map()
  def canonical_map(%__MODULE__{} = plan) do
    %{
      "compiler_version" => plan.compiler_version,
      "dependency_lock" => plan.dependency_lock,
      "effects" =>
        plan.effects |> Enum.map(&Effect.to_map/1) |> Enum.sort_by(&get_in(&1, ["site", "id"])),
      "maximum_memory" => encode_bound(plan.maximum_memory),
      "obligations" =>
        plan.obligations
        |> Enum.map(&Obligation.to_map/1)
        |> Enum.sort_by(&{get_in(&1, ["site", "id"]), &1["kind"]}),
      "policy" => Atom.to_string(plan.policy),
      "preconditions" => Enum.sort_by(plan.preconditions, & &1["variable"]),
      "regions" => plan.regions |> Enum.map(&Region.to_map/1) |> Enum.sort_by(& &1["id"]),
      "reset_points" => Enum.sort_by(plan.reset_points, & &1["id"]),
      "runtime_guards" => Enum.sort_by(plan.runtime_guards, & &1["id"]),
      "schema" => "batata-memory-plan/3",
      "source_hash" => plan.source_hash
    }
  end

  @spec canonical_json(t()) :: String.t()
  def canonical_json(%__MODULE__{} = plan), do: plan |> canonical_map() |> Memory.canonical_json()

  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = plan), do: plan |> canonical_map() |> Memory.digest()

  defp encode_bound(nil), do: nil
  defp encode_bound(%Bound{} = bound), do: Bound.canonical_map(bound)
end
