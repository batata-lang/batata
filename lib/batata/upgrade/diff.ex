defmodule Batata.Upgrade.Diff do
  @moduledoc """
  Compares two Batata export bundles (M5, tsai/beaver#29).

  Mirrors `Expandable.Upgrade.Diff` in miniature: compares the per-file digest
  index of two AOT output directories and reports additions/removals/changes,
  whether the aggregated artifact changed, and whether a migration is
  required (artifact change implies migration), plus a bundle schema drift
  (top-level fields and schema version).
  """

  @type summary() :: %{
          artifacts_changed: boolean(),
          file_surface: [map()],
          file_additions: non_neg_integer(),
          file_removals: non_neg_integer(),
          file_changes: non_neg_integer(),
          migration_required: boolean(),
          schema_drift: map()
        }

  @doc """
  Compares the export bundles of two AOT output directories.

  Returns a summary map; raises when either directory has no export bundle.
  """
  @spec compare(Path.t(), Path.t()) :: summary()
  def compare(old_dir, new_dir) do
    old_bundle = read_bundle!(old_dir)
    new_bundle = read_bundle!(new_dir)

    old_index = read_index!(old_dir)
    new_index = read_index!(new_dir)

    old_files = old_index["files"] || []
    new_files = new_index["files"] || []

    old_map = Map.new(old_files, &{&1["path"], &1["digest"]})
    new_map = Map.new(new_files, &{&1["path"], &1["digest"]})

    all_paths = Enum.uniq(Map.keys(old_map) ++ Map.keys(new_map))

    file_surface =
      Enum.map(all_paths, fn path ->
        old_digest = Map.get(old_map, path)
        new_digest = Map.get(new_map, path)

        status =
          cond do
            old_digest == nil -> "added"
            new_digest == nil -> "removed"
            old_digest == new_digest -> "unchanged"
            true -> "changed"
          end

        %{
          "path" => path,
          "old_digest" => old_digest,
          "new_digest" => new_digest,
          "status" => status
        }
      end)
      |> Enum.sort_by(& &1["path"])

    old_artifact = artifact_digest(old_bundle, old_index)
    new_artifact = artifact_digest(new_bundle, new_index)
    artifacts_changed = old_artifact != new_artifact
    schema_drift = schema_drift(old_bundle.bundle, new_bundle.bundle)

    %{
      artifacts_changed: artifacts_changed,
      file_surface: file_surface,
      file_additions: count_status(file_surface, "added"),
      file_removals: count_status(file_surface, "removed"),
      file_changes: count_status(file_surface, "changed"),
      migration_required: artifacts_changed,
      schema_drift: schema_drift
    }
  end

  @doc """
  Compares the schema shape of two export bundles: top-level field set and
  schema version.

  Status is `"unchanged"` when both shapes match, `"changed"` when the new
  bundle only adds fields (backward-compatible), and `"incompatible"` when
  fields are removed or the schema version differs.
  """
  @spec schema_drift(map(), map()) :: map()
  def schema_drift(old_bundle, new_bundle) when is_map(old_bundle) and is_map(new_bundle) do
    old_keys = old_bundle |> Map.keys() |> MapSet.new()
    new_keys = new_bundle |> Map.keys() |> MapSet.new()

    added = new_keys |> MapSet.difference(old_keys) |> Enum.sort()
    removed = old_keys |> MapSet.difference(new_keys) |> Enum.sort()

    status =
      cond do
        added == [] and removed == [] -> "unchanged"
        old_bundle["schema_version"] != new_bundle["schema_version"] -> "incompatible"
        removed == [] -> "changed"
        true -> "incompatible"
      end

    %{
      "status" => status,
      "schema_version" => %{
        "old" => old_bundle["schema_version"],
        "new" => new_bundle["schema_version"]
      },
      "fields_added" => added,
      "fields_removed" => removed
    }
  end

  defp read_index!(dir) do
    path = Batata.Export.artifact_index_path(dir)

    case File.read(path) do
      {:ok, contents} -> JSON.decode!(contents)
      {:error, reason} -> raise ArgumentError, "no export bundle at #{dir}: #{inspect(reason)}"
    end
  end

  defp read_bundle!(dir) do
    Batata.Export.read(dir) ||
      raise ArgumentError, "no export bundle at #{dir}"
  end

  # Aggregated artifact digest from bundle.json; falls back to hashing the
  # per-file digests when the bundle lacks the field (defensive).
  defp artifact_digest(%{bundle: %{"artifact_digest" => digest}}, _index), do: digest

  defp artifact_digest(_bundle, index) do
    index["files"] |> Enum.map_join(& &1["digest"]) |> hash()
  end

  defp count_status(surface, status) do
    Enum.count(surface, &(&1["status"] == status))
  end

  defp hash(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
