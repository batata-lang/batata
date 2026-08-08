defmodule Batata.Upgrade.Diff do
  @moduledoc """
  Compares two Batata export bundles (M5, tsai/beaver#29).

  Mirrors `Expandable.Upgrade.Diff` in miniature: compares the per-file digest
  index of two AOT output directories and reports additions/removals/changes,
  whether the aggregated artifact changed, and whether a migration is
  required (artifact change implies migration).
  """

  @type summary() :: %{
          artifacts_changed: boolean(),
          file_surface: [map()],
          file_additions: non_neg_integer(),
          file_removals: non_neg_integer(),
          file_changes: non_neg_integer(),
          migration_required: boolean()
        }

  @doc """
  Compares the export bundles of two AOT output directories.

  Returns a summary map; raises when either directory has no export bundle.
  """
  @spec compare(Path.t(), Path.t()) :: summary()
  def compare(old_dir, new_dir) do
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

    old_artifact = artifact_digest(old_dir, old_index)
    new_artifact = artifact_digest(new_dir, new_index)
    artifacts_changed = old_artifact != new_artifact

    %{
      artifacts_changed: artifacts_changed,
      file_surface: file_surface,
      file_additions: count_status(file_surface, "added"),
      file_removals: count_status(file_surface, "removed"),
      file_changes: count_status(file_surface, "changed"),
      migration_required: artifacts_changed
    }
  end

  defp read_index!(dir) do
    path = Batata.Export.artifact_index_path(dir)

    case File.read(path) do
      {:ok, contents} -> JSON.decode!(contents)
      {:error, reason} -> raise ArgumentError, "no export bundle at #{dir}: #{inspect(reason)}"
    end
  end

  # Aggregated artifact digest from bundle.json; falls back to hashing the
  # per-file digests when the bundle is missing (defensive).
  defp artifact_digest(dir, index) do
    case Batata.Export.read(dir) do
      %{bundle: %{"artifact_digest" => digest}} -> digest
      _ -> index["files"] |> Enum.map(& &1["digest"]) |> Enum.join() |> hash()
    end
  end

  defp count_status(surface, status) do
    Enum.count(surface, &(&1["status"] == status))
  end

  defp hash(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
