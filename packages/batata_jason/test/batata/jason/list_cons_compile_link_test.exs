defmodule Batata.Jason.ListConsCompileLinkTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CorpusCompileLink

  @tag :tmp_dir
  test "links Jason-shaped multi-head iodata construction in a qualified unit", %{
    tmp_dir: tmp_dir
  } do
    lib = Path.join(tmp_dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "escape.ex"), """
    defmodule Jason.ListConsFixture.Escape do
      def escape(byte), do: [byte]
    end
    """)

    File.write!(Path.join(lib, "encode.ex"), """
    defmodule Jason.ListConsFixture.Encode do
      def append(acc, part, byte) do
        [acc, part | Jason.ListConsFixture.Escape.escape(byte)]
      end

      def improper(acc, part, tail), do: [acc, part | tail]
    end
    """)

    result = CorpusCompileLink.run(tmp_dir)

    assert result["status"] == "pass", inspect(result)
    assert result["modules"] == 2
    assert result["unit_attempt"]["status"] == "pass"
    assert result["unresolved_internal_dependencies"] == 0
  end
end
