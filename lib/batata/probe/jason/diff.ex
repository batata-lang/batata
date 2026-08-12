defmodule Batata.Probe.Jason.Diff do
  @moduledoc "Compares two Jason probe reports by stable blocker identity."

  @doc "Returns blockers added and resolved relative to the baseline."
  @spec compare(map(), map()) :: map()
  def compare(current, baseline) do
    current_by_id = index(current)
    baseline_by_id = index(baseline)

    added_ids = Map.keys(current_by_id) -- Map.keys(baseline_by_id)
    resolved_ids = Map.keys(baseline_by_id) -- Map.keys(current_by_id)

    %{
      "added" => select(current_by_id, added_ids),
      "resolved" => select(baseline_by_id, resolved_ids),
      "unchanged" => map_size(current_by_id) - length(added_ids),
      "regression" => added_ids != []
    }
  end

  defp index(report), do: Map.new(report["blockers"], &{&1["id"], &1})

  defp select(index, ids) do
    ids
    |> Enum.sort()
    |> Enum.map(&Map.fetch!(index, &1))
  end
end
