defmodule Batata.Probe.Jason.Report do
  @moduledoc """
  Builds a deterministic, machine-readable Jason frontend probe report.

  A blocker is identified by its source path, declared module, line, reason,
  and normalized form. The identifier makes reports comparable across Batata
  commits while the stage classification separates compile-time/frontend gaps
  from later semantic, lowering, and runtime failures.
  """

  alias Batata.Probe.Jason.Inventory

  @schema_version 2
  @known_stages ~w(
    parse
    macro_or_compile_time
    frontend_normalization
    pattern_or_guard
    term_or_stdlib_surface
    protocol_or_dispatch
    control_flow_or_exception
    ir_verification
    lowering_or_link
    runtime_result_mismatch
    pass
  )

  @doc "Builds a report for a Jason project or `lib` directory."
  @spec build(Path.t(), keyword()) :: map()
  def build(source, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    files = Inventory.discover!(source)
    {ignored_metadata, blockers} = entries(files)

    %{
      "schema_version" => @schema_version,
      "corpus" => corpus(metadata, files),
      "toolchain" => %{
        "elixir" => System.version(),
        "otp" => System.otp_release()
      },
      "stages" => @known_stages,
      "summary" => summary(files, blockers, ignored_metadata),
      "ignored_metadata" => ignored_metadata,
      "blockers" => blockers
    }
  end

  @doc "Writes a report as JSON and returns the report map."
  @spec write!(Path.t(), Path.t(), keyword()) :: map()
  def write!(source, output, opts \\ []) do
    report = build(source, opts)
    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, JSON.encode!(report))
    report
  end

  @doc "Reads probe source metadata from JSON."
  @spec read_metadata!(Path.t()) :: map()
  def read_metadata!(path), do: path |> File.read!() |> JSON.decode!()

  defp entries(files) do
    entries =
      files
      |> Enum.flat_map(&file_entries/1)
      |> Enum.sort_by(&{&1["path"], &1["module"], &1["line"], &1["reason"], &1["id"]})

    Enum.split_with(entries, &(&1["reason"] == "ignored_metadata"))
  end

  defp file_entries(%{status: :parse_error} = file) do
    error = file.parse_error

    [
      blocker(%{
        "path" => file.path,
        "module" => nil,
        "line" => nil,
        "reason" => "parse_error",
        "frontend_reason" => "parse_error",
        "form" => "#{error.description}: #{error.token}",
        "stage" => "parse"
      })
    ]
  end

  defp file_entries(file) do
    top_level =
      Enum.map(file.top_level_unsupported, &blocker_entry(file.path, nil, &1))

    modules =
      Enum.flat_map(file.modules, fn module ->
        Enum.map(module.unsupported, &blocker_entry(file.path, module.module, &1))
      end)

    top_level ++ modules
  end

  defp blocker_entry(path, module, unsupported) do
    entry = %{
      "path" => path,
      "module" => module,
      "line" => unsupported.line,
      "reason" => to_string(unsupported.reason),
      "frontend_reason" => to_string(unsupported.frontend_reason),
      "form" => unsupported.form,
      "stage" => stage(unsupported.reason)
    }

    entry =
      case Map.fetch(unsupported, :attribute) do
        {:ok, attribute} -> Map.put(entry, "attribute", to_string(attribute))
        :error -> entry
      end

    blocker(entry)
  end

  defp blocker(entry) do
    identity =
      ~w(path module line reason form)
      |> Enum.map_join("\0", &to_string(entry[&1]))

    Map.put(entry, "id", digest(identity))
  end

  defp stage(reason)
       when reason in [
              :module_attribute,
              :import,
              :require,
              :use,
              :alias,
              :defmacro,
              :defmacrop
            ],
       do: "macro_or_compile_time"

  defp stage(:ignored_metadata), do: "ignored_metadata"
  defp stage(reason) when reason in [:defprotocol, :defimpl], do: "protocol_or_dispatch"
  defp stage(:guarded_definition), do: "pattern_or_guard"
  defp stage(_reason), do: "frontend_normalization"

  defp corpus(metadata, files) do
    %{
      "name" => Map.get(metadata, "name", "jason"),
      "repository" => Map.get(metadata, "repository"),
      "ref" => Map.get(metadata, "ref"),
      "commit" => Map.get(metadata, "commit"),
      "source_digest" => files |> Enum.map_join(& &1.digest) |> digest(),
      "files" => length(files)
    }
  end

  defp summary(files, blockers, ignored_metadata) do
    modules = Enum.sum(Enum.map(files, &length(&1.modules)))

    definitions =
      Enum.sum(for file <- files, module <- file.modules, do: length(module.definitions))

    counts = Enum.frequencies_by(blockers, & &1["stage"])

    %{
      "files" => length(files),
      "modules" => modules,
      "definitions" => definitions,
      "blockers" => length(blockers),
      "ignored_metadata" => length(ignored_metadata),
      "ignored_metadata_by_attribute" => Enum.frequencies_by(ignored_metadata, & &1["attribute"]),
      "by_stage" => Map.new(@known_stages, &{&1, Map.get(counts, &1, 0)})
    }
  end

  defp digest(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
