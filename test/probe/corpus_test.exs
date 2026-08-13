defmodule Batata.Probe.CorpusTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Corpus

  @tag :tmp_dir
  test "runs the existing report pipeline with corpus-neutral paths", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "decimal")
    output = Path.join(tmp_dir, "report.json")
    metadata_path = Path.join(tmp_dir, "source.json")
    File.mkdir_p!(Path.join(source, "lib"))

    File.write!(Path.join(source, "lib/decimal.ex"), """
    defmodule Decimal do
      def add(left, right), do: left + right
    end
    """)

    File.write!(
      metadata_path,
      JSON.encode!(%{
        "name" => "decimal",
        "repository" => "https://example.invalid/decimal.git",
        "ref" => "v2.3.0",
        "commit" => String.duplicate("a", 40)
      })
    )

    report =
      Corpus.run!(source,
        name: "Decimal",
        output: output,
        metadata: metadata_path
      )

    assert report == output |> File.read!() |> JSON.decode!()
    assert report["corpus"]["name"] == "decimal"
    assert report["schema_version"] == 3
    assert report["coverage_claim"] == "no library-definition compile coverage"
    assert report["summary"]["definitions"] == 1
    assert report["summary"]["ignored_metadata"] == 0
    assert report["ignored_metadata"] == []
  end
end
