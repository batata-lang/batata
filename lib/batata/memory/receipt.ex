defmodule Batata.Memory.Receipt do
  @moduledoc "A bounded-memory proof receipt; inventory-only M0 plans cannot create one."

  alias Batata.Memory
  alias Batata.Memory.{Bound, Plan}

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
    runtime_limits: [],
    runtime_guards: [],
    unproven_obligations: []
  ]

  @type t :: %__MODULE__{}

  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    receipt = struct!(__MODULE__, opts)

    unless receipt.assurance == :bounded do
      raise ArgumentError, "batata-memory-receipt/2 requires :bounded assurance"
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
      "runtime_limits" => receipt.runtime_limits,
      "runtime_guards" => receipt.runtime_guards,
      "schema" => "batata-memory-receipt/2",
      "source_hash" => receipt.source_hash,
      "unproven_obligations" => receipt.unproven_obligations
    }
  end

  @spec canonical_json(t()) :: String.t()
  def canonical_json(%__MODULE__{} = receipt),
    do: receipt |> canonical_map() |> Memory.canonical_json()

  @doc "Builds a receipt only from a closed plan with an evaluable maximum."
  @spec from_plan!(Plan.t(), map()) :: t()
  def from_plan!(plan, contracts \\ %{})

  def from_plan!(%Plan{obligations: []} = plan, contracts) do
    maximum =
      case plan.maximum_memory do
        %Bound{} = bound ->
          case Bound.evaluate(bound, contracts) do
            {:ok, bytes} ->
              bytes

            {:error, missing} ->
              raise ArgumentError, "memory receipt has unresolved contracts: #{inspect(missing)}"
          end

        nil ->
          raise ArgumentError, "memory receipt requires a closed maximum_memory bound"
      end

    new!(
      source_hash: plan.source_hash,
      compiler_version: plan.compiler_version,
      dependency_lock: plan.dependency_lock,
      memory_plan_hash: "sha256:" <> Plan.digest(plan),
      maximum_memory: Integer.to_string(maximum),
      runtime_limits: plan.runtime_limits,
      runtime_guards: plan.runtime_guards
    )
  end

  def from_plan!(%Plan{obligations: obligations}, _contracts) do
    raise ArgumentError,
          "memory receipt requires zero unproven obligations, got: #{length(obligations)}"
  end

  @doc "Verifies a receipt against a canonical plan without compiler process state."
  @spec verify(t(), Plan.t(), map()) :: :ok | {:error, atom()}
  def verify(%__MODULE__{} = receipt, %Plan{} = plan, contracts \\ %{}) do
    with %Bound{} <- plan.maximum_memory,
         true <- receipt.source_hash == plan.source_hash,
         true <- receipt.compiler_version == plan.compiler_version,
         true <- receipt.dependency_lock == plan.dependency_lock,
         true <- receipt.memory_plan_hash == "sha256:" <> Plan.digest(plan),
         [] <- plan.obligations,
         {:ok, maximum} <- Bound.evaluate(plan.maximum_memory, contracts),
         true <- receipt.maximum_memory == Integer.to_string(maximum),
         true <- receipt.runtime_limits == plan.runtime_limits,
         true <- receipt.runtime_guards == plan.runtime_guards do
      :ok
    else
      false -> {:error, :receipt_mismatch}
      [_ | _] -> {:error, :unproven_obligations}
      {:error, _missing} -> {:error, :unresolved_contracts}
      nil -> {:error, :missing_maximum}
    end
  end

  @doc "Verifies canonical receipt and plan JSON bytes without compiler process state."
  @spec verify_json(String.t(), String.t()) :: :ok | {:error, atom()}
  def verify_json(receipt_json, plan_json)
      when is_binary(receipt_json) and is_binary(plan_json) do
    with {:ok, receipt} <- decode_canonical(receipt_json),
         {:ok, plan} <- decode_canonical(plan_json),
         true <- receipt["schema"] == "batata-memory-receipt/2",
         true <- receipt["assurance"] == "bounded",
         true <- plan["schema"] == "batata-memory-plan/4",
         [] <- receipt["unproven_obligations"],
         [] <- plan["obligations"],
         true <- receipt["source_hash"] == plan["source_hash"],
         true <- receipt["compiler_version"] == plan["compiler_version"],
         true <- receipt["dependency_lock"] == plan["dependency_lock"],
         true <- receipt["memory_plan_hash"] == "sha256:" <> Memory.digest(plan),
         true <- receipt["runtime_limits"] == plan["runtime_limits"],
         true <- receipt["runtime_guards"] == plan["runtime_guards"],
         {:ok, maximum} <- Bound.evaluate_map(plan["maximum_memory"], contracts_from(plan)),
         true <- receipt["maximum_memory"] == Integer.to_string(maximum) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _missing} -> {:error, :unresolved_contracts}
      [_ | _] -> {:error, :unproven_obligations}
      false -> {:error, :receipt_mismatch}
      _other -> {:error, :invalid_receipt}
    end
  rescue
    _error -> {:error, :invalid_receipt}
  end

  defp decode_canonical(json) do
    canonical = String.trim_trailing(json, "\n")

    try do
      decoded = JSON.decode!(canonical)

      if Memory.canonical_json(decoded) == canonical,
        do: {:ok, decoded},
        else: {:error, :noncanonical_json}
    rescue
      _error -> {:error, :invalid_json}
    end
  end

  defp contracts_from(plan) do
    Map.new(plan["preconditions"], fn precondition ->
      {precondition["variable"], String.to_integer(precondition["maximum_bytes"])}
    end)
  end

  defp valid_non_negative_integer_string?(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> Integer.to_string(integer) == value
      _ -> false
    end
  end

  defp valid_non_negative_integer_string?(_value), do: false
end
