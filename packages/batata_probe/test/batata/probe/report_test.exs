defmodule Batata.Probe.ReportTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.{Diff, Report}

  @tag :tmp_dir
  test "writes deterministic blocker stages and corpus identity", %{tmp_dir: tmp_dir} do
    source_dir = Path.join(tmp_dir, "jason")
    File.mkdir_p!(Path.join(source_dir, "lib"))

    File.write!(Path.join(source_dir, "lib/decoder.ex"), """
    defmodule Jason.Decoder do
      @moduledoc false
      @compile {:inline, plain: 1}
      import Bitwise
      def parse(data) when is_binary(data), do: data
      def plain(data), do: data
    end
    """)

    metadata = %{
      "name" => "jason",
      "ref" => "v1.4.5",
      "commit" => "abc",
      "repository" => "https://example.invalid/jason.git"
    }

    first = Report.build(source_dir, metadata: metadata)
    second = Report.build(source_dir, metadata: metadata)

    assert first == second
    assert first["schema_version"] == 6

    assert first["coverage_claim"] ==
             "eligible-module compile attempts; no per-definition coverage"

    assert first["harness_contract"] == %{
             "harness" => "synthetic non-executing main/0 appended iff missing",
             "original_forms" => true,
             "scope" => "target-module-body"
           }

    assert first["scope_limits"] == [
             "top-level forms only",
             "macro calls inside definition bodies are not attributed",
             "single-module compile attempts; cross-module calls are not resolvable"
           ]

    assert first["corpus"]["ref"] == "v1.4.5"
    assert first["summary"]["definitions"] == 2
    assert first["summary"]["blockers"] == 1
    assert first["summary"]["by_stage"]["macro_or_compile_time"] == 1
    assert first["summary"]["by_stage"]["pattern_or_guard"] == 0
    assert first["summary"]["ignored_metadata"] == 2

    assert first["summary"]["ignored_metadata_by_attribute"] == %{
             "compile" => 1,
             "moduledoc" => 1
           }

    assert first["summary"]["dependency_frontier"] == %{
             "blocked_calls" => 0,
             "calls" => 0,
             "corpus_calls" => 0,
             "eligible_calls" => 0,
             "targets" => 0
           }

    assert first["dependency_frontier"] == []
    assert first["closure_frontier"] == []
    assert first["diagnostic_attempts"] == []
    assert first["generation_attempts"] == []

    assert first["summary"]["diagnostic_attempts"] == %{
             "outcomes" => %{},
             "phases" => %{},
             "total" => 0
           }

    assert first["summary"]["generation_attempts"] == %{
             "expanded_definitions" => 0,
             "phases" => %{},
             "total" => 0
           }

    assert first["summary"]["closure_frontier"] == %{
             "by_provenance" => %{
               "caller_parameter" => 0,
               "cross_module_capture" => 0,
               "module_local" => 0,
               "other_external" => 0
             },
             "modules" => 0,
             "sites" => 0
           }

    assert first["summary"]["module_compile_attempts"] == %{
             "blocked_by_module_forms" => 1,
             "frontend_normalization_failure" => 0,
             "ir_verification_failure" => 0,
             "lowering_failure" => 0,
             "pass" => 0
           }

    assert first["module_compile_attempts"] == [
             %{
               "blocker_categories" => %{"import" => 1},
               "module" => "Jason.Decoder",
               "path" => "lib/decoder.ex",
               "status" => "blocked_by_module_forms",
               "harness" => %{
                 "original_forms" => true,
                 "scope" => "target-module-body",
                 "synthetic_main" => true
               }
             }
           ]

    assert first["summary"]["categories"] == %{"import" => 1}
    assert first["summary"]["generation_constructs"] == %{}
    assert first["summary"]["generation_roots"] == %{}

    assert Enum.map(first["ignored_metadata"], & &1["attribute"]) == ["moduledoc", "compile"]

    assert Enum.all?(first["blockers"], &(byte_size(&1["id"]) == 64))
    assert Enum.all?(first["ignored_metadata"], &(byte_size(&1["id"]) == 64))
  end

  @tag :tmp_dir
  test "reports module generation constructs without changing blocker identity", %{
    tmp_dir: tmp_dir
  } do
    source_dir = Path.join(tmp_dir, "corpus")
    File.mkdir_p!(Path.join(source_dir, "lib"))

    File.write!(Path.join(source_dir, "lib/generation.ex"), """
    defmodule Generation do
      table = Enum.zip([1], [2])
      if enabled(), do: :ok
      Enum.each([1], fn item -> defp generated(), do: item end)
      annotate(:value)
    end
    """)

    report = Report.build(source_dir)

    assert report["summary"]["generation_constructs"] == %{
             "definition_generation" => 1,
             "generator_control" => 1,
             "module_call" => 1,
             "module_match" => 1
           }

    assert report["summary"]["generation_roots"] == %{
             "=/2" => 1,
             "Enum.each/2" => 1,
             "annotate/1" => 1,
             "if/2" => 1
           }

    assert Enum.all?(report["blockers"], fn blocker ->
             blocker["reason"] == "module_level_generation" and
               is_binary(blocker["generation_construct"]) and
               is_binary(blocker["generation_root"]) and byte_size(blocker["id"]) == 64
           end)
  end

  test "diff reports added and resolved blocker identities" do
    keep = %{"id" => "keep", "reason" => "import"}
    enriched_keep = Map.put(keep, "generation_construct", "module_call")
    old = %{"id" => "old", "reason" => "module_attribute"}
    new = %{"id" => "new", "reason" => "guarded_definition"}

    metadata_keep = %{"id" => "metadata-keep", "attribute" => "doc"}
    metadata_new = %{"id" => "metadata-new", "attribute" => "spec"}

    current_attempts = [
      %{"path" => "lib/pass.ex", "module" => "Pass", "status" => "lowering_failure"}
    ]

    baseline_attempts = [
      %{"path" => "lib/pass.ex", "module" => "Pass", "status" => "pass"}
    ]

    current_diagnostics = [
      diagnostic("Added", "lowering_complete", "added"),
      diagnostic("Changed", "ir_verification_failure", "changed"),
      diagnostic("Fingerprint", "lowering_complete", "new")
    ]

    baseline_diagnostics = [
      diagnostic("Removed", "lowering_complete", "removed"),
      diagnostic("Changed", "frontend_normalization_failure", "changed"),
      diagnostic("Fingerprint", "lowering_complete", "old")
    ]

    diff =
      Diff.compare(
        %{
          "blockers" => [enriched_keep, new],
          "ignored_metadata" => [metadata_keep, metadata_new],
          "module_compile_attempts" => current_attempts,
          "diagnostic_attempts" => current_diagnostics
        },
        %{
          "blockers" => [keep, old],
          "ignored_metadata" => [metadata_keep],
          "module_compile_attempts" => baseline_attempts,
          "diagnostic_attempts" => baseline_diagnostics
        }
      )

    assert diff["added"] == [new]
    assert diff["resolved"] == [old]
    assert diff["unchanged"] == 1
    assert diff["regression"]
    assert diff["ignored_metadata_added"] == [metadata_new]
    assert diff["ignored_metadata_resolved"] == []
    assert diff["ignored_metadata_unchanged"] == 1
    assert diff["compile_attempt_regression"]

    assert diff["compile_attempt_changes"] == [
             %{
               "from" => "pass",
               "module" => "Pass",
               "path" => "lib/pass.ex",
               "to" => "lowering_failure"
             }
           ]

    assert Enum.map(diff["diagnostic_attempt_changes"], &{&1["module"], &1["kind"]}) == [
             {"Added", "added"},
             {"Changed", "changed"},
             {"Fingerprint", "fingerprint_only"},
             {"Removed", "removed"}
           ]

    changed = Enum.find(diff["diagnostic_attempt_changes"], &(&1["module"] == "Changed"))
    assert changed["from"]["phase"] == "frontend_normalization_failure"
    assert changed["to"]["phase"] == "ir_verification_failure"

    refute Diff.compare(
             %{"diagnostic_attempts" => current_diagnostics},
             %{"diagnostic_attempts" => baseline_diagnostics}
           )["regression"]
  end

  test "diagnostic-only changes do not produce a nil regression flag" do
    current = %{
      "blockers" => [],
      "ignored_metadata" => [],
      "module_compile_attempts" => [],
      "diagnostic_attempts" => [diagnostic("Added", "lowering_complete", "added")]
    }

    baseline = %{
      "blockers" => [],
      "ignored_metadata" => [],
      "module_compile_attempts" => [],
      "diagnostic_attempts" => []
    }

    assert Diff.compare(current, baseline)["regression"] == false
  end

  defp diagnostic(module, phase, fingerprint) do
    %{
      "path" => "lib/#{String.downcase(module)}.ex",
      "module" => module,
      "outcome" => "reached_compile_pipeline",
      "error" => "Batata.Lift.Error",
      "phase" => phase,
      "reason_class" => "guarded_definition",
      "fingerprint" => fingerprint
    }
  end
end
