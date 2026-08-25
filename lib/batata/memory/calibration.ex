defmodule Batata.Memory.Calibration do
  @moduledoc "Fail-closed comparison between a memory proof and native execution telemetry."

  alias Batata.Memory
  alias Batata.Memory.{Bound, Plan}

  defmodule Error do
    @moduledoc "Raised when native telemetry contradicts a memory proof."
    defexception [:message, :report]
  end

  @spec compare(Plan.t(), map()) :: {:ok, map()} | {:error, map()}
  def compare(%Plan{} = plan, telemetry) when is_map(telemetry) do
    observed = fetch_integer!(telemetry, "arena_high_water_bytes")
    runtime_limit = fetch_integer!(telemetry, "arena_limit_bytes")
    oom = Map.fetch!(telemetry, "oom")
    typed_failure = Map.get(telemetry, "typed_failure")
    plan_limit = plan_limit!(plan)

    proof =
      case Bound.evaluate(plan.maximum_memory) do
        {:ok, maximum} ->
          maximum

        {:error, variables} ->
          raise ArgumentError, "memory proof remains symbolic: #{inspect(variables)}"
      end

    invariants = [
      invariant("telemetry-within-proof", observed <= proof, observed, proof),
      invariant(
        "telemetry-within-runtime-limit",
        observed <= runtime_limit,
        observed,
        runtime_limit
      ),
      invariant(
        "runtime-limit-matches-plan",
        runtime_limit == plan_limit,
        runtime_limit,
        plan_limit
      ),
      invariant("oom-is-typed", not oom or typed_failure == "arena_oom", oom, typed_failure)
    ]

    status = if Enum.all?(invariants, & &1["satisfied"]), do: "matched", else: "contradiction"

    report = %{
      "invariants" => invariants,
      "observed_high_water_bytes" => observed,
      "plan_hash" => "sha256:" <> Plan.digest(plan),
      "proved_maximum_bytes" => proof,
      "runtime_limit_bytes" => runtime_limit,
      "schema" => "batata-memory-calibration/1",
      "status" => status,
      "telemetry" => telemetry
    }

    if status == "matched", do: {:ok, report}, else: {:error, report}
  end

  @spec compare!(Plan.t(), map()) :: map()
  def compare!(%Plan{} = plan, telemetry) do
    case compare(plan, telemetry) do
      {:ok, report} -> report
      {:error, report} -> raise Error, message: Memory.canonical_json(report), report: report
    end
  end

  defp plan_limit!(plan) do
    case Enum.find(plan.runtime_limits, &(&1["id"] == "execution-arena")) do
      %{"effective_bytes" => value} -> parse_integer!(value, "plan runtime limit")
      _ -> raise ArgumentError, "memory plan is missing the execution-arena runtime limit"
    end
  end

  defp fetch_integer!(map, key), do: map |> Map.fetch!(key) |> parse_integer!(key)
  defp parse_integer!(value, _name) when is_integer(value) and value >= 0, do: value

  defp parse_integer!(value, name) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> raise ArgumentError, "#{name} must be a non-negative integer"
    end
  end

  defp parse_integer!(_value, name),
    do: raise(ArgumentError, "#{name} must be a non-negative integer")

  defp invariant(id, satisfied, observed, expected) do
    %{"expected" => expected, "id" => id, "observed" => observed, "satisfied" => satisfied}
  end
end
