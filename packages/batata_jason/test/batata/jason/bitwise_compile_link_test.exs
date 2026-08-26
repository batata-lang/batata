defmodule Batata.Jason.BitwiseCompileLinkTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CorpusCompileLink

  @tag :tmp_dir
  test "links Jason-shaped imported shifts and masks in a qualified unit", %{tmp_dir: tmp_dir} do
    lib = Path.join(tmp_dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "unicode.ex"), """
    defmodule Jason.BitwiseFixture.Unicode do
      import Bitwise, only: [&&&: 2, |||: 2, <<<: 2, >>>: 2]

      def decode(first, last) do
        ((first &&& 0x3F) <<< 10) ||| (last &&& 0x3FF)
      end

      def encode(char), do: 0x800 ||| (char >>> 10)
    end
    """)

    File.write!(Path.join(lib, "entry.ex"), """
    defmodule Jason.BitwiseFixture.Entry do
      def transcode(first, last) do
        char = Jason.BitwiseFixture.Unicode.decode(first, last)
        Jason.BitwiseFixture.Unicode.encode(char)
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
