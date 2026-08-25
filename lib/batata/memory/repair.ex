defmodule Batata.Memory.Repair do
  @moduledoc "Canonical AI-native repair requests derived from compiler-owned obligations."

  alias Batata.Memory
  alias Batata.Memory.{Obligation, Plan, Receipt, Strategy}

  @doc "Builds a replayable repair request; the input plan remains the authority."
  @spec canonical_map(Plan.t()) :: map()
  def canonical_map(%Plan{} = plan) do
    obstructions =
      plan.obligations
      |> Enum.sort_by(&{&1.site.id, to_string(&1.kind)})
      |> Enum.map(fn obligation ->
        %{
          "candidates" => Strategy.candidates(obligation),
          "obligation" => Obligation.to_map(obligation)
        }
      end)

    %{
      "compiler_version" => plan.compiler_version,
      "dependency_lock" => plan.dependency_lock,
      "full_recompute_required" => true,
      "memory_plan_hash" => "sha256:" <> Plan.digest(plan),
      "obstructions" => obstructions,
      "protocol" => "batata-memory-repair/1",
      "source_hash" => plan.source_hash,
      "submit" => %{
        "action" => "recompile-full-plan",
        "acceptance" => "receipt verification succeeds and residual obligations equal zero"
      }
    }
  end

  @spec canonical_json(Plan.t()) :: String.t()
  def canonical_json(%Plan{} = plan), do: plan |> canonical_map() |> Memory.canonical_json()

  @doc "Accepts only a fully recomputed closed plan and its compiler-issued receipt."
  @spec verify_recomputed(Plan.t(), Plan.t(), Receipt.t(), map()) :: :ok | {:error, atom()}
  def verify_recomputed(
        %Plan{} = previous,
        %Plan{} = recomputed,
        %Receipt{} = receipt,
        contracts \\ %{}
      ) do
    cond do
      previous.compiler_version != recomputed.compiler_version -> {:error, :compiler_changed}
      previous.dependency_lock != recomputed.dependency_lock -> {:error, :dependency_changed}
      recomputed.obligations != [] -> {:error, :residual_obligations}
      true -> Receipt.verify(receipt, recomputed, contracts)
    end
  end
end
