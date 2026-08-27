defmodule Batata.Jason.BinaryPartCompileLinkTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CorpusCompileLink

  @tag :tmp_dir
  test "links Jason-shaped binary_part calls in a qualified unit", %{tmp_dir: tmp_dir} do
    lib = Path.join(tmp_dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "decoder.ex"), """
    defmodule Jason.BinaryPartFixture.Decoder do
      def token(original, skip, length), do: binary_part(original, skip, length)
    end
    """)

    File.write!(Path.join(lib, "encode.ex"), """
    defmodule Jason.BinaryPartFixture.Encode do
      def chunk(original, skip, length) do
        Jason.BinaryPartFixture.Decoder.token(original, skip, length)
      end
    end
    """)

    result = CorpusCompileLink.run(tmp_dir)

    assert result["status"] == "pass", inspect(result)
    assert result["modules"] == 2
    assert result["unit_attempt"]["status"] == "pass"
    assert result["unresolved_internal_dependencies"] == 0
  end
end
