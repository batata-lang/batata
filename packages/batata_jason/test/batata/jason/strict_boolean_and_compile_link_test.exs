defmodule Batata.Jason.StrictBooleanAndCompileLinkTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CorpusCompileLink

  @tag :tmp_dir
  test "links Jason escapeu-shaped strict boolean and conditions", %{tmp_dir: tmp_dir} do
    lib = Path.join(tmp_dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "decoder.ex"), """
    defmodule Jason.StrictBooleanAndFixture.Decoder do
      def escapeu(<<last>>) do
        if 0 == 0 and last <= 127, do: 1, else: 0
      end
    end
    """)

    result = CorpusCompileLink.run(tmp_dir)

    assert result["status"] == "pass", inspect(result)
    assert result["modules"] == 1
    assert result["unit_attempt"]["status"] == "pass"
    assert result["unresolved_internal_dependencies"] == 0
  end
end
