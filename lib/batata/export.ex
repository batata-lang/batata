defmodule Batata.Export do
  @moduledoc """
  Export bundle metadata for AOT artifacts (M5, tsai/beaver#29).

  `Batata.build/3` emits the native artifacts; this module records what was
  built and how, so two builds of the same source are comparable and an
  upgrade diff can decide whether migration is required. The schema is kept
  deliberately small: module/entry/source digest/runtime version/artifact
  digest, plus a per-file digest index.
  """

  @schema_version 1

  @doc "Path of the bundle descriptor inside an AOT output directory."
  def bundle_path(output_dir), do: Path.join(output_dir, "bundle.json")

  @doc "Path of the per-file digest index inside an AOT output directory."
  def artifact_index_path(output_dir), do: Path.join(output_dir, "artifact_index.json")

  @doc "Path of the build manifest inside an AOT output directory."
  def manifest_path(output_dir), do: Path.join(output_dir, "manifest.json")

  @doc """
  Writes `bundle.json`, `artifact_index.json` and `manifest.json` into an AOT
  output directory and returns their paths.

  The artifact digest aggregates the digests of the native artifacts (archive
  and object), so any object-level change flips `artifacts_changed` in the
  upgrade diff.
  """
  @spec write!(Path.t(), module(), keyword()) :: %{
          bundle: Path.t(),
          artifact_index: Path.t(),
          manifest: Path.t()
        }
  def write!(output_dir, module_name, opts) do
    source = Keyword.fetch!(opts, :source)
    artifact_paths = Keyword.get(opts, :artifact_paths, [])

    source_digest = digest(source)
    artifact_digest = artifact_paths |> Enum.map(&digest_file/1) |> join_digests()
    runtime_version = runtime_version()

    bundle =
      %{
        "schema_version" => @schema_version,
        "module" => inspect(module_name),
        "entry" => "batata_main",
        "source_digest" => source_digest,
        "runtime_version" => runtime_version,
        "artifact_digest" => artifact_digest
      }

    files =
      artifact_paths
      |> Enum.map(fn path ->
        %{"path" => Path.basename(path), "digest" => digest_file(path)}
      end)
      |> Enum.sort_by(& &1["path"])

    manifest =
      %{
        "compiler" => "batata",
        "version" => Mix.Project.config()[:version],
        "elixir" => System.version(),
        "schema_version" => @schema_version
      }

    bundle_path = bundle_path(output_dir)
    index_path = artifact_index_path(output_dir)
    manifest_path = manifest_path(output_dir)

    write_json!(bundle_path, bundle)
    write_json!(index_path, %{"files" => files})
    write_json!(manifest_path, manifest)

    %{bundle: bundle_path, artifact_index: index_path, manifest: manifest_path}
  end

  @doc """
  Reads a bundle directory's metadata (all three files), or `nil` when the
  directory has no export bundle.
  """
  @spec read(Path.t()) :: map() | nil
  def read(output_dir) do
    with {:ok, bundle} <- read_json(bundle_path(output_dir)),
         {:ok, index} <- read_json(artifact_index_path(output_dir)),
         {:ok, manifest} <- read_json(manifest_path(output_dir)) do
      %{bundle: bundle, artifact_index: index, manifest: manifest}
    else
      _ -> nil
    end
  end

  @doc "Digest of the Zig runtime ABI manifest, so ABI changes flip the bundle."
  def runtime_version do
    abi = Path.expand("native/ABI.md", File.cwd!())

    if File.exists?(abi) do
      digest(File.read!(abi))
    else
      "unknown"
    end
  end

  defp write_json!(path, value) do
    File.write!(path, JSON.encode!(value))
  end

  defp read_json(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, JSON.decode!(contents)}
      {:error, _reason} -> :error
    end
  end

  defp digest(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp digest_file(path) do
    case File.read(path) do
      {:ok, contents} -> digest(contents)
      {:error, _reason} -> "missing"
    end
  end

  defp join_digests(digests), do: digests |> Enum.join() |> digest()
end
