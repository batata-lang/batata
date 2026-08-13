defmodule Batata.Probe.Jason.Diff do
  @moduledoc "Compares two Jason probe reports by stable blocker identity."

  @doc "Returns blockers added and resolved relative to the baseline."
  @spec compare(map(), map()) :: map()
  def compare(current, baseline) do
    blocker_diff = compare_entries(current, baseline, "blockers")
    metadata_diff = compare_entries(current, baseline, "ignored_metadata")
    compile_diff = compare_compile_attempts(current, baseline)

    Map.merge(blocker_diff, %{
      "ignored_metadata_added" => metadata_diff["added"],
      "ignored_metadata_resolved" => metadata_diff["resolved"],
      "ignored_metadata_unchanged" => metadata_diff["unchanged"],
      "compile_attempt_changes" => compile_diff.changes,
      "compile_attempt_regression" => compile_diff.regression,
      "regression" => blocker_diff["regression"] or compile_diff.regression
    })
  end

  defp compare_compile_attempts(current, baseline) do
    current = compile_index(current)
    baseline = compile_index(baseline)

    changes =
      baseline
      |> Enum.flat_map(fn {key, previous} ->
        case Map.get(current, key) do
          nil ->
            [%{"path" => elem(key, 0), "module" => elem(key, 1), "from" => previous, "to" => nil}]

          ^previous ->
            []

          status ->
            [
              %{
                "path" => elem(key, 0),
                "module" => elem(key, 1),
                "from" => previous,
                "to" => status
              }
            ]
        end
      end)
      |> Enum.sort_by(&{&1["path"], &1["module"]})

    %{
      changes: changes,
      regression: Enum.any?(changes, &(&1["from"] == "pass" and &1["to"] != "pass"))
    }
  end

  defp compile_index(report) do
    report
    |> Map.get("module_compile_attempts", [])
    |> Map.new(fn entry -> {{entry["path"], entry["module"]}, entry["status"]} end)
  end

  defp compare_entries(current, baseline, key) do
    current_by_id = index(current, key)
    baseline_by_id = index(baseline, key)

    added_ids = Map.keys(current_by_id) -- Map.keys(baseline_by_id)
    resolved_ids = Map.keys(baseline_by_id) -- Map.keys(current_by_id)

    %{
      "added" => select(current_by_id, added_ids),
      "resolved" => select(baseline_by_id, resolved_ids),
      "unchanged" => map_size(current_by_id) - length(added_ids),
      "regression" => key == "blockers" and added_ids != []
    }
  end

  defp index(report, key), do: Map.new(Map.get(report, key, []), &{&1["id"], &1})

  defp select(index, ids) do
    ids
    |> Enum.sort()
    |> Enum.map(&Map.fetch!(index, &1))
  end
end
