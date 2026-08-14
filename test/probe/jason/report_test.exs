defmodule Batata.Probe.Jason.ReportTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.{Diff, Report}

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
    assert first["schema_version"] == 4

    assert first["coverage_claim"] ==
             "eligible-module compile attempts; no per-definition coverage"

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
    assert first["diagnostic_attempts"] == []

    assert first["summary"]["diagnostic_attempts"] == %{
             "outcomes" => %{},
             "phases" => %{},
             "total" => 0
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
               "status" => "blocked_by_module_forms"
             }
           ]

    assert first["summary"]["categories"] == %{"import" => 1}

    assert Enum.map(first["ignored_metadata"], & &1["attribute"]) == ["moduledoc", "compile"]

    assert Enum.all?(first["blockers"], &(byte_size(&1["id"]) == 64))
    assert Enum.all?(first["ignored_metadata"], &(byte_size(&1["id"]) == 64))
  end

  test "diff reports added and resolved blocker identities" do
    keep = %{"id" => "keep", "reason" => "import"}
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
          "blockers" => [keep, new],
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

  test "committed corpus baselines contain no supported alias blockers" do
    jason = "probe/jason/baseline.json" |> File.read!() |> JSON.decode!()
    decimal = "probe/decimal/baseline.json" |> File.read!() |> JSON.decode!()

    assert jason["summary"]["categories"]["alias"] == nil
    assert decimal["summary"]["categories"]["alias"] == nil
    assert jason["summary"]["blockers"] == 72
    assert decimal["summary"]["blockers"] == 42
    assert jason["summary"]["ignored_metadata"] == 77
    assert decimal["summary"]["ignored_metadata"] == 106
    assert jason["summary"]["definitions"] == 239
    assert decimal["summary"]["definitions"] == 243

    assert jason["summary"]["dependency_frontier"] == %{
             "blocked_calls" => 109,
             "calls" => 120,
             "corpus_calls" => 18,
             "eligible_calls" => 11,
             "targets" => 24
           }

    assert decimal["summary"]["dependency_frontier"] == %{
             "blocked_calls" => 70,
             "calls" => 70,
             "corpus_calls" => 11,
             "eligible_calls" => 0,
             "targets" => 11
           }

    assert Enum.any?(jason["dependency_frontier"], fn call ->
             call["module"] == "Jason" and call["target"] == "Jason.Decoder" and
               call["function"] == "parse" and call["target_kind"] == "corpus"
           end)

    assert Enum.any?(jason["dependency_frontier"], fn call ->
             call["module"] == "Jason.Encode" and call["target"] == "Map" and
               call["function"] == "put" and
               call["source_eligibility"] == "blocked_by_module_forms" and
               call["blocker_categories"]["module_level_generation"] == 24
           end)

    assert [%{"reason_class" => "remote_module_call", "module" => "Jason"}] =
             Enum.filter(
               jason["module_compile_attempts"],
               &(&1["status"] == "frontend_normalization_failure")
             )

    assert Enum.find(jason["diagnostic_attempts"], &(&1["module"] == "Jason.DecodeError"))[
             "phase"
           ] == "lowering_complete"

    assert Enum.find(jason["diagnostic_attempts"], &(&1["module"] == "Jason.EncodeError"))[
             "phase"
           ] == "lowering_complete"

    refute Map.has_key?(
             Enum.find(jason["diagnostic_attempts"], &(&1["module"] == "Jason.EncodeError")),
             "reason_class"
           )

    assert Enum.any?(jason["diagnostic_attempts"], fn attempt ->
             attempt["module"] == "Jason.DecodeError" and
               attempt["phase"] == "lowering_complete" and
               not Map.has_key?(attempt, "reason_class")
           end)

    assert Enum.any?(jason["diagnostic_attempts"], fn attempt ->
             attempt["module"] == "Jason.OrderedObject" and
               attempt["outcome"] == "reached_compile_pipeline" and
               attempt["error"] == "Batata.Lower.Error" and
               attempt["phase"] == "lowering_failure" and
               attempt["reason_class"] == "lowering_pass_failure" and
               Enum.map(attempt["removed_blockers"], & &1["reason"]) == ["struct_semantics"]
           end)

    refute Enum.any?(jason["diagnostic_attempts"], &(&1["module"] == "Jason.Fragment"))

    assert Enum.all?(jason["diagnostic_attempts"], fn attempt ->
             attempt["diagnostic_only"] and not Map.has_key?(attempt, "status") and
               Enum.all?(attempt["removed_blockers"], fn removed ->
                 Enum.any?(jason["blockers"], &(&1["id"] == removed["id"]))
               end)
           end)

    assert Enum.any?(decimal["diagnostic_attempts"], fn attempt ->
             attempt["module"] == "Decimal.Error" and
               attempt["outcome"] == "reached_compile_pipeline" and
               attempt["phase"] == "lowering_complete" and
               not Map.has_key?(attempt, "reason_class")
           end)

    assert Enum.any?(decimal["diagnostic_attempts"], fn attempt ->
             attempt["module"] == "Decimal.Macros" and
               attempt["outcome"] == "synthetic_only" and
               attempt["phase"] == "not_attempted"
           end)
  end
end
