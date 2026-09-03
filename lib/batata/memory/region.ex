defmodule Batata.Memory.Region do
  @moduledoc """
  Logical memory regions and their honest physical backend mapping.

  Batata currently has one segmented execution arena plus retained exported
  host storage. Logical lexical, actor, and execution regions remain useful
  proof domains, but this schema never claims that they are separate physical
  allocators.
  """

  alias Batata.Memory.{Effect, Obligation}

  @enforce_keys [:id, :kind, :physical_backend, :lifetime]
  defstruct [:id, :kind, :physical_backend, :lifetime, capabilities: [], reset: nil]

  @type kind :: :register | :lexical | :actor | :execution | :persistent
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          physical_backend: String.t(),
          lifetime: map(),
          capabilities: [String.t()],
          reset: map() | nil
        }

  @doc "Returns the logical region selected for an allocation effect."
  @spec kind_for(Effect.classification(), Batata.Memory.Lifetime.escape()) :: kind()
  def kind_for(:none, _escape), do: :register
  def kind_for(_classification, :local), do: :lexical
  def kind_for(_classification, :process_send), do: :actor
  def kind_for(_classification, :exported_host), do: :persistent
  def kind_for(_classification, _escape), do: :execution

  @doc "Builds canonical descriptors for every region used by the plan."
  @spec descriptors([Effect.t()], [map()]) :: {[t()], [map()], [Obligation.t()]}
  def descriptors(effects, operation_sequences) do
    {reset_points, reset_obligations} = verified_reset_points(effects, operation_sequences)

    regions =
      effects
      |> Enum.map(& &1.region)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&descriptor(&1, reset_points))

    {regions, reset_points, reset_obligations}
  end

  @doc "Checks the required runtime-enter/reset/result/runtime-leave ordering."
  @spec verify_reset_sequence([String.t()]) :: :ok | {:error, String.t()}
  def verify_reset_sequence(operations) when is_list(operations) do
    with {:ok, enter} <- index_of(operations, "ex.runtime_enter"),
         {:ok, reset} <- index_of(operations, "ex.process_table_reset"),
         {:ok, result} <- index_of_any(operations, ["ex.result_create", "ex.result_create_term"]),
         {:ok, leave} <- index_of(operations, "ex.runtime_leave"),
         true <- enter < reset and reset < result and result < leave do
      :ok
    else
      :error -> {:error, "required execution reset operation is missing"}
      false -> {:error, "execution reset operations are not in lifecycle order"}
    end
  end

  @doc "Canonical JSON-ready representation of a region descriptor."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = region) do
    %{
      "capabilities" => Enum.sort(region.capabilities),
      "id" => region.id,
      "kind" => Atom.to_string(region.kind),
      "lifetime" => region.lifetime,
      "physical_backend" => region.physical_backend,
      "reset" => region.reset
    }
  end

  defp verified_reset_points(effects, operation_sequences) do
    reset_effect = Enum.find(effects, &(&1.context["operation"] == "ex.process_table_reset"))

    verification =
      Enum.find_value(
        operation_sequences,
        {:error, "execution driver is unreachable"},
        fn sequence ->
          case verify_reset_sequence(sequence.operations) do
            :ok -> {:ok, sequence.function}
            {:error, _reason} -> false
          end
        end
      )

    case {reset_effect, verification} do
      {%Effect{} = effect, {:ok, function}} ->
        point = %{
          "after" => "runtime-enter",
          "before" => "user-entry",
          "function" => function,
          "id" => "reset:" <> effect.site.id,
          "preconditions" => ["zero outstanding pins", "execution quiescence"],
          "site_id" => effect.site.id,
          "verified" => true
        }

        {[point], []}

      {%Effect{} = effect, {:error, reason}} ->
        obligation =
          Obligation.new!(
            kind: :reset_boundary_unverified,
            site: effect.site,
            missing_fact: reason,
            context: effect.context,
            strategies: [
              %{
                "action" => "restore-verified-reset-boundary",
                "required_order" => [
                  "ex.runtime_enter",
                  "ex.process_table_reset",
                  "ex.result_create or ex.result_create_term",
                  "ex.runtime_leave"
                ]
              }
            ]
          )

        {[], [obligation]}

      {nil, _verification} ->
        {[], []}
    end
  end

  defp descriptor(:register, _reset_points) do
    new(:register, "immediate-or-register", %{"end" => "value-last-use"}, ["zero-allocation"])
  end

  defp descriptor(:lexical, reset_points) do
    new(
      :lexical,
      "segmented-bump-execution-arena",
      %{"end" => "execution-reset", "logical_scope" => "lexical"},
      ["immutable-sharing"],
      reset(reset_points)
    )
  end

  defp descriptor(:actor, reset_points) do
    new(
      :actor,
      "segmented-bump-execution-arena",
      %{"end" => "execution-quiescence", "logical_scope" => "actor-message"},
      ["immutable-sharing", "cross-actor-retention"],
      reset(reset_points)
    )
  end

  defp descriptor(:execution, reset_points) do
    new(
      :execution,
      "segmented-bump-execution-arena",
      %{"end" => "last-pin-release", "logical_scope" => "request"},
      ["generation-pinning", "immutable-sharing"],
      reset(reset_points)
    )
  end

  defp descriptor(:persistent, _reset_points) do
    new(
      :persistent,
      "retained-exported-host-storage",
      %{"end" => "export-handle-destroy", "logical_scope" => "host"},
      ["deep-copy", "portable", "generation-checked"]
    )
  end

  defp new(kind, backend, lifetime, capabilities, reset \\ nil) do
    %__MODULE__{
      id: "region:" <> Atom.to_string(kind),
      kind: kind,
      physical_backend: backend,
      lifetime: lifetime,
      capabilities: capabilities,
      reset: reset
    }
  end

  defp reset([point | _]), do: %{"point_id" => point["id"], "verified" => true}
  defp reset([]), do: nil

  defp index_of(values, target) do
    case Enum.find_index(values, &(&1 == target)) do
      nil -> :error
      index -> {:ok, index}
    end
  end

  defp index_of_any(values, targets) do
    values
    |> Enum.with_index()
    |> Enum.find_value(:error, fn {value, index} ->
      if value in targets, do: {:ok, index}
    end)
  end
end
