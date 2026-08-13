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
    assert first["schema_version"] == 2
    assert first["corpus"]["ref"] == "v1.4.5"
    assert first["summary"]["definitions"] == 2
    assert first["summary"]["blockers"] == 2
    assert first["summary"]["by_stage"]["macro_or_compile_time"] == 2
    assert first["summary"]["by_stage"]["pattern_or_guard"] == 0
    assert first["summary"]["ignored_metadata"] == 1
    assert first["summary"]["ignored_metadata_by_attribute"] == %{"moduledoc" => 1}

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

    diff =
      Diff.compare(
        %{"blockers" => [keep, new], "ignored_metadata" => [metadata_keep, metadata_new]},
        %{"blockers" => [keep, old], "ignored_metadata" => [metadata_keep]}
      )

    assert diff["added"] == [new]
    assert diff["resolved"] == [old]
    assert diff["unchanged"] == 1
    assert diff["regression"]
    assert diff["ignored_metadata_added"] == [metadata_new]
    assert diff["ignored_metadata_resolved"] == []
    assert diff["ignored_metadata_unchanged"] == 1
  end
end
