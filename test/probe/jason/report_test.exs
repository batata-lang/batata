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
    assert first["schema_version"] == 3

    assert first["coverage_claim"] ==
             "eligible-module compile attempts; no per-definition coverage"

    assert first["scope_limits"] == [
             "top-level forms only",
             "macro calls inside definition bodies are not attributed",
             "single-module compile attempts; cross-module calls are not resolvable"
           ]

    assert first["corpus"]["ref"] == "v1.4.5"
    assert first["summary"]["definitions"] == 2
    assert first["summary"]["blockers"] == 2
    assert first["summary"]["by_stage"]["macro_or_compile_time"] == 2
    assert first["summary"]["by_stage"]["pattern_or_guard"] == 0
    assert first["summary"]["ignored_metadata"] == 1
    assert first["summary"]["ignored_metadata_by_attribute"] == %{"moduledoc" => 1}

    assert first["summary"]["dependency_frontier"] == %{
             "calls" => 0,
             "corpus_calls" => 0,
             "targets" => 0
           }

    assert first["dependency_frontier"] == []

    assert first["summary"]["module_compile_attempts"] == %{
             "blocked_by_module_forms" => 1,
             "frontend_normalization_failure" => 0,
             "ir_verification_failure" => 0,
             "lowering_failure" => 0,
             "pass" => 0
           }

    assert first["module_compile_attempts"] == [
             %{
               "blocker_categories" => %{"compile_annotation" => 1, "import" => 1},
               "module" => "Jason.Decoder",
               "path" => "lib/decoder.ex",
               "status" => "blocked_by_module_forms"
             }
           ]

    assert first["summary"]["categories"] == %{
             "compile_annotation" => 1,
             "import" => 1
           }

    assert [%{"attribute" => "moduledoc", "reason" => "ignored_metadata"}] =
             first["ignored_metadata"]

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

    diff =
      Diff.compare(
        %{
          "blockers" => [keep, new],
          "ignored_metadata" => [metadata_keep, metadata_new],
          "module_compile_attempts" => current_attempts
        },
        %{
          "blockers" => [keep, old],
          "ignored_metadata" => [metadata_keep],
          "module_compile_attempts" => baseline_attempts
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
  end

  test "committed corpus baselines contain no supported alias blockers" do
    jason = "probe/jason/baseline.json" |> File.read!() |> JSON.decode!()
    decimal = "probe/decimal/baseline.json" |> File.read!() |> JSON.decode!()

    assert jason["summary"]["categories"]["alias"] == nil
    assert decimal["summary"]["categories"]["alias"] == nil
    assert jason["summary"]["blockers"] == 85
    assert decimal["summary"]["blockers"] == 43
    assert jason["summary"]["definitions"] == 239
    assert decimal["summary"]["definitions"] == 243

    assert jason["summary"]["dependency_frontier"] == %{
             "calls" => 11,
             "corpus_calls" => 6,
             "targets" => 5
           }

    assert decimal["summary"]["dependency_frontier"] == %{
             "calls" => 0,
             "corpus_calls" => 0,
             "targets" => 0
           }

    assert Enum.any?(jason["dependency_frontier"], fn call ->
             call["module"] == "Jason" and call["target"] == "Jason.Decoder" and
               call["function"] == "parse" and call["target_kind"] == "corpus"
           end)

    assert [%{"reason_class" => "remote_module_call", "module" => "Jason"}] =
             Enum.filter(
               jason["module_compile_attempts"],
               &(&1["status"] == "frontend_normalization_failure")
             )
  end
end
