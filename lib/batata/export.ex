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
    definitions = Keyword.get(opts, :definitions, [])

    source_digest = digest(source)
    artifact_digest = artifact_paths |> Enum.map(&digest_file/1) |> join_digests()
    runtime_version = runtime_version()
    exports = Keyword.get_lazy(opts, :exports, fn -> exports(definitions, module_name) end)
    entry = Keyword.get(opts, :entry, "batata_main")
    bundle_metadata = validate_bundle_metadata!(Keyword.get(opts, :bundle_metadata, %{}))

    bundle =
      Map.merge(bundle_metadata, %{
        "schema_version" => @schema_version,
        "module" => inspect(module_name),
        "entry" => entry,
        "source_digest" => source_digest,
        "runtime_version" => runtime_version,
        "artifact_digest" => artifact_digest,
        "exports" => exports
      })

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
    abi = Path.join(Batata.TermRuntime.native_dir(), "ABI.md")

    if File.exists?(abi) do
      digest(File.read!(abi))
    else
      "unknown"
    end
  end

  @doc """
  Symbol-level export list for the snapshot's definitions.

  The entry function is renamed to `batata_main` by `Batata.build/3`; every
  other definition uses the same arity-qualified internal symbol as the
  compiler-generated LLVM function.
  """
  @spec exports([Batata.Frontend.Definition.t()], module(), atom()) :: [map()]
  def exports(definitions, module_name, entry_name \\ :main) do
    module_part =
      module_name
      |> Atom.to_string()
      |> String.replace_leading("Elixir.", "")

    Enum.map(definitions, fn definition ->
      entry? = definition.name == :batata_main

      symbol =
        if entry?,
          do: "batata_main",
          else: Batata.Symbol.function(definition.name, definition.arity)

      function = if entry?, do: to_string(entry_name), else: to_string(definition.name)

      %{
        "function" => "#{module_part}.#{function}/#{definition.arity}",
        "symbol" => symbol
      }
    end)
    |> Enum.sort_by(& &1["function"])
  end

  @doc """
  Verifies that every exported symbol is defined in the archive (via `nm`).
  Raises with the missing symbols otherwise.
  """
  @spec verify_symbols!(Path.t(), [map()]) :: :ok
  def verify_symbols!(archive_path, exports) do
    defined = defined_symbols!(archive_path, exact: false)

    missing =
      exports
      |> Enum.map(& &1["symbol"])
      |> Enum.reject(&MapSet.member?(defined, &1))

    if missing != [] do
      raise ArgumentError,
            "exported symbols missing from #{Path.basename(archive_path)}: #{inspect(missing)}"
    end

    :ok
  end

  @doc "Verifies that a dynamic library exports exactly the declared C symbols."
  @spec verify_exact_symbols!(Path.t(), [map()]) :: :ok
  def verify_exact_symbols!(library_path, exports) do
    actual = defined_symbols!(library_path, exact: true)
    expected = exports |> Enum.map(& &1["symbol"]) |> MapSet.new()

    if actual != expected do
      raise ArgumentError,
            "dynamic export surface mismatch for #{Path.basename(library_path)}: " <>
              "missing=#{inspect(MapSet.difference(expected, actual) |> MapSet.to_list())} " <>
              "unexpected=#{inspect(MapSet.difference(actual, expected) |> MapSet.to_list())}"
    end

    :ok
  end

  defp write_json!(path, value) do
    File.write!(path, JSON.encode!(value))
  end

  defp validate_bundle_metadata!(metadata) when is_map(metadata) do
    if Enum.all?(Map.keys(metadata), &is_binary/1) do
      metadata
    else
      raise ArgumentError, "bundle metadata keys must be strings"
    end
  end

  defp validate_bundle_metadata!(_metadata),
    do: raise(ArgumentError, "bundle metadata must be a map")

  defp defined_symbols!(path, opts) do
    {tool, arguments, format} = symbol_command!(path, Keyword.fetch!(opts, :exact))
    {output, 0} = System.cmd(tool, arguments, stderr_to_stdout: true)

    output
    |> parse_defined_symbols(format)
    |> Enum.map(&normalize_c_symbol/1)
    |> MapSet.new()
  end

  defp symbol_command!(path, exact?) do
    case {:os.type(), exact?} do
      {{:win32, _}, true} ->
        dumpbin = System.find_executable("dumpbin") || raise "dumpbin not found on PATH"
        {dumpbin, ["/nologo", "/exports", path], :dumpbin}

      {{:unix, :darwin}, true} ->
        nm = System.find_executable("nm") || raise "nm not found on PATH"
        {nm, ["-gU", path], :nm}

      {_, true} ->
        nm = System.find_executable("nm") || raise "nm not found on PATH"
        {nm, ["-g", "--defined-only", path], :nm}

      {_, false} ->
        nm = System.find_executable("nm") || raise "nm not found on PATH"
        {nm, ["-g", path], :nm}
    end
  end

  @doc false
  def parse_defined_symbols(output, :nm) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/(?:^|\s)([A-Za-z?])\s+(\S+)\s*$/, line) do
        [_, type, symbol] when type not in ["U", "u"] -> [symbol]
        _ -> []
      end
    end)
  end

  def parse_defined_symbols(output, :dumpbin) do
    output
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)/, line) do
        [_, symbol] -> [symbol]
        _ -> []
      end
    end)
  end

  defp normalize_c_symbol(symbol) do
    case :os.type() do
      {:unix, :darwin} -> String.replace_prefix(symbol, "_", "")
      _ -> symbol
    end
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
