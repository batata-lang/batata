defmodule Batata.Probe.Coverage do
  @moduledoc """
  Builds the campaign dashboard for pinned, unmodified source corpora.

  Raw inventory, canonical frontend acceptance, whole-corpus linking, and
  executable semantic gates are deliberately reported as separate levels.
  A green level never implies that a later level is green.
  """

  alias Batata.Frontend
  alias Batata.Frontend.BytecaseExpand
  alias Batata.Frontend.MetadataMacroExpand
  alias Batata.Frontend.SigilMacroExpand
  alias Batata.Frontend.StaticMapMacroExpand
  alias Batata.Probe.CapabilityMatrix
  alias Batata.Probe.CorpusCompileLink
  alias Batata.Probe.{Diff, Report}

  @schema_version 2
  @levels ~w(raw_inventory canonical_acceptance corpus_compile_link semantic_execution)

  @spec run!([map()], Path.t(), keyword()) :: map()
  def run!(corpora, output, opts \\ []) when is_list(corpora) do
    results = corpora |> Enum.map(&corpus_result!/1) |> Map.new(&{&1["name"], &1})

    dashboard = %{
      "schema_version" => @schema_version,
      "coverage_claim" =>
        "complete coverage requires canonical acceptance, whole-corpus compile/link, and oracle-backed semantic execution",
      "levels" => @levels,
      "corpora" => results
    }

    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, JSON.encode!(dashboard))

    if Keyword.get(opts, :fail_on_regression, false) do
      regressions =
        results
        |> Map.values()
        |> Enum.flat_map(& &1["regressions"])

      if regressions != [] do
        Mix.raise("coverage regression: #{Enum.join(regressions, "; ")}")
      end
    end

    dashboard
  end

  @doc "Merges already computed single- or multi-corpus dashboards without rerunning probes."
  @spec merge!([Path.t()], Path.t()) :: map()
  def merge!(inputs, output) when is_list(inputs) and inputs != [] do
    dashboards = Enum.map(inputs, &read_json!/1)
    [first | rest] = dashboards
    validate_dashboard!(first)

    corpora =
      Enum.reduce(rest, first["corpora"], fn dashboard, corpora ->
        validate_dashboard!(dashboard)

        unless dashboard["levels"] == first["levels"] and
                 dashboard["coverage_claim"] == first["coverage_claim"] do
          raise ArgumentError, "coverage dashboard contracts do not match"
        end

        Map.merge(corpora, dashboard["corpora"], fn name, _left, _right ->
          raise ArgumentError, "duplicate coverage corpus #{name}"
        end)
      end)

    merged = Map.put(first, "corpora", corpora)
    output |> Path.dirname() |> File.mkdir_p!()
    File.write!(output, JSON.encode!(merged))
    merged
  end

  defp validate_dashboard!(%{
         "schema_version" => @schema_version,
         "coverage_claim" => claim,
         "levels" => @levels,
         "corpora" => corpora
       })
       when is_binary(claim) and is_map(corpora) and map_size(corpora) > 0,
       do: :ok

  defp validate_dashboard!(_dashboard) do
    raise ArgumentError, "invalid coverage dashboard"
  end

  defp corpus_result!(config) do
    name = Map.fetch!(config, :name)
    source = Map.fetch!(config, :source)
    baseline = config |> Map.fetch!(:baseline) |> read_json!()
    metadata = config |> Map.fetch!(:metadata) |> Report.read_metadata!()
    capabilities = config |> Map.fetch!(:capabilities) |> CapabilityMatrix.load!()
    canonical_baseline = read_optional_json(config[:canonical_baseline])
    link_baseline = read_optional_json(config[:link_baseline])

    raw =
      case Map.get(config, :raw_report) do
        nil -> Report.build(source, metadata: metadata)
        path -> read_json!(path)
      end

    verify_source_identity!(raw, metadata)
    verify_canonical_identity!(canonical_baseline, metadata)
    verify_link_identity!(link_baseline, metadata)
    diff = Diff.compare(raw, baseline)
    canonical = canonical_acceptance(source)
    compile_link = CorpusCompileLink.run(source)
    semantic = semantic_execution(capabilities)

    regressions = raw_regressions(diff) ++ canonical_regressions(canonical, canonical_baseline)

    %{
      "name" => name,
      "source" => raw["corpus"],
      "claim" => claim(canonical, compile_link, semantic),
      "regressions" => regressions,
      "raw_inventory" => %{
        "status" => if(regressions == [], do: "preserved", else: "changed"),
        "baseline" => raw_summary(baseline),
        "current" => raw_summary(raw),
        "target" => %{"identity" => "preserved and explicitly classified"},
        "diff" => %{
          "added_ids" => Enum.map(diff["added"], & &1["id"]),
          "resolved_ids" => Enum.map(diff["resolved"], & &1["id"]),
          "compile_attempt_regression" => diff["compile_attempt_regression"]
        }
      },
      "canonical_acceptance" => %{
        "status" => if(canonical["unsupported_forms"] == 0, do: "pass", else: "blocked"),
        "baseline" => canonical_baseline,
        "current" => canonical,
        "target" => %{"failed_files" => 0, "unsupported_forms" => 0}
      },
      "corpus_compile_link" => %{
        "status" => compile_link["status"],
        "baseline" => link_baseline,
        "current" => compile_link,
        "target" => %{"status" => "pass", "unresolved_internal_dependencies" => 0}
      },
      "semantic_execution" => %{
        "status" => if(semantic["blocked"] == 0, do: "pass", else: "blocked"),
        "baseline" => semantic,
        "current" => semantic,
        "target" => %{"blocked" => 0, "oracle_backed" => semantic["total"]}
      }
    }
  end

  defp raw_summary(report) do
    %{
      "blockers" => report["summary"]["blockers"],
      "definitions" => report["summary"]["definitions"],
      "module_compile_attempts" => report["summary"]["module_compile_attempts"]
    }
  end

  defp raw_regressions(diff) do
    []
    |> maybe_regression(diff["added"] != [], "raw blocker IDs added")
    |> maybe_regression(diff["resolved"] != [], "raw blocker IDs disappeared")
    |> maybe_regression(diff["compile_attempt_regression"], "module compile attempt regressed")
  end

  defp canonical_regressions(_canonical, nil), do: []

  defp canonical_regressions(canonical, baseline) do
    []
    |> maybe_regression(
      canonical["failed_files"] > baseline["failed_files"],
      "canonical failed files increased"
    )
    |> maybe_regression(
      canonical["unsupported_forms"] > baseline["unsupported_forms"],
      "canonical unsupported forms increased"
    )
    |> Kernel.++(canonical_file_regressions(canonical["results"], baseline["results"]))
  end

  defp canonical_file_regressions(results, baseline_results) do
    baseline_by_path = Map.new(baseline_results, &{&1["path"], &1})

    Enum.flat_map(results, fn result ->
      baseline = Map.get(baseline_by_path, result["path"], %{"reasons" => %{}})

      Enum.flat_map(result["reasons"] || %{}, fn {reason, count} ->
        canonical_reason_regression(result["path"], reason, count, baseline)
      end)
    end)
  end

  defp canonical_reason_regression(path, reason, count, baseline) do
    baseline_count = get_in(baseline, ["reasons", reason]) || 0

    if count > baseline_count do
      ["#{path}: canonical #{reason} increased from #{baseline_count} to #{count}"]
    else
      []
    end
  end

  defp maybe_regression(regressions, true, message), do: regressions ++ [message]
  defp maybe_regression(regressions, false, _message), do: regressions

  defp canonical_acceptance(source) do
    files = source_files(source)
    sources = Enum.map(files, &File.read!/1)
    metadata_macros = MetadataMacroExpand.discover(sources)
    table_generators = Frontend.MetaprogrammingExpand.discover_table_generators(sources)
    bytecase_macros = BytecaseExpand.discover(sources)
    static_map_macros = StaticMapMacroExpand.discover(sources)
    sigil_macros = SigilMacroExpand.discover(sources)

    results =
      files
      |> Enum.zip(sources)
      |> Enum.map(fn {path, source_text} ->
        canonical_file(
          path,
          source,
          source_text,
          metadata_macros,
          table_generators,
          bytecase_macros,
          static_map_macros,
          sigil_macros
        )
      end)

    %{
      "files" => length(results),
      "modules" => Enum.sum_by(results, & &1["modules"]),
      "failed_files" => Enum.count(results, &(&1["status"] == "error")),
      "unsupported_forms" => Enum.sum_by(results, & &1["unsupported_forms"]),
      "results" => results
    }
  end

  defp source_files(source) do
    root = if File.dir?(Path.join(source, "lib")), do: Path.join(source, "lib"), else: source
    root |> Path.join("**/*.ex") |> Path.wildcard() |> Enum.sort()
  end

  defp canonical_file(
         path,
         source,
         source_text,
         metadata_macros,
         table_generators,
         bytecase_macros,
         static_map_macros,
         sigil_macros
       ) do
    relative = Path.relative_to(path, source)

    try do
      modules =
        source_text
        |> Frontend.from_source(
          metadata_macros: metadata_macros,
          table_generators: table_generators,
          bytecase_macros: bytecase_macros,
          static_map_macros: static_map_macros,
          sigil_macros: sigil_macros
        )
        |> List.wrap()

      unsupported = Enum.flat_map(modules, & &1.unsupported)

      %{
        "path" => relative,
        "status" => if(unsupported == [], do: "pass", else: "unsupported"),
        "modules" => length(modules),
        "unsupported_forms" => length(unsupported),
        "reasons" => Enum.frequencies_by(unsupported, &to_string(&1.reason))
      }
    rescue
      error ->
        %{
          "path" => relative,
          "status" => "error",
          "modules" => 0,
          "unsupported_forms" => 1,
          "error" => inspect(error.__struct__),
          "fingerprint" => error |> Exception.message() |> digest()
        }
    end
  end

  defp semantic_execution(%{"capabilities" => capabilities}) do
    statuses = Enum.frequencies_by(capabilities, & &1["status"])

    %{
      "total" => length(capabilities),
      "oracle_backed" => Map.get(statuses, "executable", 0),
      "blocked" => Map.get(statuses, "blocked", 0),
      "blocked_ids" =>
        capabilities
        |> Enum.filter(&(&1["status"] == "blocked"))
        |> Enum.map(& &1["id"])
        |> Enum.sort()
    }
  end

  defp claim(%{"unsupported_forms" => 0}, %{"status" => "pass"}, %{"blocked" => 0}),
    do: "complete compile/link and semantic coverage"

  defp claim(%{"unsupported_forms" => 0}, %{"status" => "pass"}, _semantic),
    do: "whole-corpus compile/link coverage; semantic execution is still required"

  defp claim(%{"unsupported_forms" => 0}, _compile_link, %{"blocked" => 0}),
    do: "compile coverage; whole-corpus link is still required"

  defp claim(_canonical, _compile_link, _semantic),
    do: "inventory and partial semantic coverage only"

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()

  defp read_optional_json(nil), do: nil
  defp read_optional_json(path), do: read_json!(path)

  defp verify_source_identity!(report, metadata) do
    corpus = report["corpus"]

    if corpus["commit"] != metadata["commit"] or corpus["ref"] != metadata["ref"] do
      raise ArgumentError,
            "raw report corpus identity does not match #{metadata["name"]} metadata"
    end
  end

  defp verify_canonical_identity!(nil, _metadata), do: :ok

  defp verify_canonical_identity!(baseline, metadata) do
    corpus = baseline["corpus"]

    if corpus["commit"] != metadata["commit"] or corpus["ref"] != metadata["ref"] do
      raise ArgumentError,
            "canonical baseline corpus identity does not match #{metadata["name"]} metadata"
    end
  end

  defp verify_link_identity!(nil, _metadata), do: :ok

  defp verify_link_identity!(baseline, metadata) do
    corpus = baseline["corpus"] || %{}

    unless corpus["name"] == metadata["name"] and corpus["ref"] == metadata["ref"] and
             corpus["commit"] == metadata["commit"] do
      raise ArgumentError,
            "link baseline corpus identity does not match #{metadata["name"]} metadata"
    end
  end

  defp digest(message),
    do: :crypto.hash(:sha256, message) |> Base.encode16(case: :lower)
end
