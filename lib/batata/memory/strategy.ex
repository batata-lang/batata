defmodule Batata.Memory.Strategy do
  @moduledoc "Versioned repair strategy catalog for machine-operated memory remediation."

  @catalog [
    %{
      "id" => "set-memory-contract",
      "available" => true,
      "changes" => "compile-options",
      "preconditions" => ["derive a conservative non-negative upper bound"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "set-runtime-quota",
      "available" => true,
      "changes" => "compile-options",
      "preconditions" => ["arena_oom is an accepted typed failure effect"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "reduce-memory-bound",
      "available" => true,
      "changes" => "source-or-layout-policy",
      "preconditions" => ["the recomputed allocation bound fits the native hard limit"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "classify-intrinsic",
      "available" => true,
      "changes" => "compiler-summary",
      "preconditions" => ["summary is derived from the pinned runtime implementation"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "declare-external-summary",
      "available" => true,
      "changes" => "native-provider-plan",
      "preconditions" => ["callee identity and allocation contract are stable"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "derive-callee-summary",
      "available" => true,
      "changes" => "source-or-compiler-summary",
      "preconditions" => ["callee is reachable in the compilation unit"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "restore-verified-reset-boundary",
      "available" => true,
      "changes" => "compiler-pipeline",
      "preconditions" => ["reset follows runtime enter and precedes user entry"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "copy-to-receiver-region",
      "available" => false,
      "changes" => "physical-layout-policy",
      "preconditions" => ["receiver region backend is enabled"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "promote-shared-immutable",
      "available" => false,
      "changes" => "physical-layout-policy",
      "preconditions" => ["shared immutable backend is enabled"],
      "recompute" => "full-plan"
    },
    %{
      "id" => "use-refcounted-large-binary",
      "available" => false,
      "changes" => "physical-layout-policy",
      "preconditions" => ["refcounted large-binary backend is enabled"],
      "recompute" => "full-plan"
    }
  ]

  @doc "Returns the complete deterministic catalog."
  @spec catalog() :: [map()]
  def catalog, do: @catalog

  @doc "Returns catalog entries referenced by an obligation's current hints."
  @spec candidates(Batata.Memory.Obligation.t()) :: [map()]
  def candidates(obligation) do
    requested =
      obligation.strategies
      |> Enum.map(&(&1["action"] || &1["id"]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    @catalog
    |> Enum.filter(&MapSet.member?(requested, &1["id"]))
    |> Enum.map(fn strategy ->
      hint = Enum.find(obligation.strategies, &((&1["action"] || &1["id"]) == strategy["id"]))
      Map.put(strategy, "parameters", Map.drop(hint || %{}, ["action", "id"]))
    end)
    |> Enum.sort_by(& &1["id"])
  end
end
