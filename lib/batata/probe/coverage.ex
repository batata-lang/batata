defmodule Batata.Probe.Coverage do
  @moduledoc """
  Builds the campaign dashboard for pinned, unmodified source corpora.

  Raw inventory, canonical frontend acceptance, whole-corpus linking, and
  executable semantic gates are deliberately reported as separate levels.
  A green level never implies that a later level is green.
  """

  alias Batata.Frontend
  alias Batata.Probe.CapabilityMatrix
  alias Batata.Probe.Jason.{Diff, Report}

  @schema_version 1
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

  defp corpus_result!(config) do
    name = Map.fetch!(config, :name)
    source = Map.fetch!(config, :source)
    baseline = config |> Map.fetch!(:baseline) |> read_json!()
    metadata = config |> Map.fetch!(:metadata) |> Report.read_metadata!()
    capabilities = config |> Map.fetch!(:capabilities) |> CapabilityMatrix.load!()

    raw =
      case Map.get(config, :raw_report) do
        nil -> Report.build(source, metadata: metadata)
        path -> read_json!(path)
      end

    verify_source_identity!(raw, metadata)
    diff = Diff.compare(raw, baseline)
    canonical = canonical_acceptance(source)
    semantic = semantic_execution(capabilities)

    regressions = raw_regressions(diff)

    %{
      "name" => name,
      "source" => raw["corpus"],
      "claim" => claim(canonical, semantic),
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
        "baseline" => nil,
        "current" => canonical,
        "target" => %{"failed_files" => 0, "unsupported_forms" => 0}
      },
      "corpus_compile_link" => %{
        "status" => "blocked",
        "baseline" => nil,
        "current" => %{
          "reason" => "dependency-aware whole-corpus compile/link runner is not implemented"
        },
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

  defp maybe_regression(regressions, true, message), do: regressions ++ [message]
  defp maybe_regression(regressions, false, _message), do: regressions

  defp canonical_acceptance(source) do
    files = source_files(source)
    results = Enum.map(files, &canonical_file(&1, source))

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

  defp canonical_file(path, source) do
    relative = Path.relative_to(path, source)

    try do
      modules = path |> File.read!() |> Frontend.from_source() |> List.wrap()
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

  defp claim(%{"unsupported_forms" => 0}, %{"blocked" => 0}),
    do: "compile coverage; whole-corpus link is still required"

  defp claim(_canonical, _semantic), do: "inventory and partial semantic coverage only"

  defp read_json!(path), do: path |> File.read!() |> JSON.decode!()

  defp verify_source_identity!(report, metadata) do
    corpus = report["corpus"]

    if corpus["commit"] != metadata["commit"] or corpus["ref"] != metadata["ref"] do
      raise ArgumentError,
            "raw report corpus identity does not match #{metadata["name"]} metadata"
    end
  end

  defp digest(message),
    do: :crypto.hash(:sha256, message) |> Base.encode16(case: :lower)
end
