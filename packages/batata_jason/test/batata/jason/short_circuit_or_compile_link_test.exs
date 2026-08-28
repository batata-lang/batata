defmodule Batata.Jason.ShortCircuitOrCompileLinkTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CorpusCompileLink

  @tag :tmp_dir
  test "links Jason-shaped short-circuit or calls in a qualified unit", %{tmp_dir: tmp_dir} do
    lib = Path.join(tmp_dir, "lib")
    File.mkdir_p!(lib)

    File.write!(Path.join(lib, "formatter.ex"), """
    defmodule Jason.ShortCircuitOrFixture.Formatter do
      def parse_opts(record, line, value) do
        {record || value, record || line}
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
