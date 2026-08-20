defmodule Batata.Probe.CorpusCompileLinkTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.CorpusCompileLink

  @tag :tmp_dir
  test "passes a single module through frontend, lift, and lowering", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "sample.ex", """
    defmodule Sample do
      def identity(value), do: value
    end
    """)

    assert %{
             "status" => "pass",
             "mode" => "shared_frontend_isolated_lowering",
             "modules" => 1,
             "isolated_passes" => 1,
             "unresolved_internal_dependencies" => 0,
             "attempts" => [%{"module" => "Sample", "status" => "pass"}],
             "reason" => nil
           } = CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "keeps a multi-module dependency blocked until it shares one IR unit", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "callee.ex", """
    defmodule Callee do
      def double(value), do: value * 2
    end
    """)

    write_source(tmp_dir, "caller.ex", """
    defmodule Caller do
      def call(value), do: Callee.double(value)
    end
    """)

    result = CorpusCompileLink.run(tmp_dir)

    assert result["status"] == "blocked"
    assert result["reason"] == "dependency_aware_multi_module_unit_not_implemented"
    assert result["modules"] == 2

    assert result["internal_dependencies"] == [
             %{
               "caller" => "Caller",
               "callee" => "Callee",
               "function" => "double",
               "arity" => 1
             }
           ]

    assert result["unresolved_internal_dependencies"] == 1
    assert Enum.any?(result["attempts"], &(&1["status"] == "frontend_normalization_failure"))
  end

  defp write_source(root, name, contents) do
    lib = Path.join(root, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, name), contents)
  end
end
