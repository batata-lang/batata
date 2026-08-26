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
             "mode" => "qualified_multi_module_unit",
             "modules" => 1,
             "isolated_passes" => 1,
             "unresolved_internal_dependencies" => 0,
             "attempts" => [%{"module" => "Sample", "status" => "pass"}],
             "reason" => nil
           } = CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "resolves a cross-module call inside one qualified IR unit", %{tmp_dir: tmp_dir} do
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

    assert result["status"] == "pass"
    assert result["reason"] == nil
    assert result["modules"] == 2

    assert result["internal_dependencies"] == [
             %{
               "caller" => "Caller",
               "callee" => "Callee",
               "function" => "double",
               "arity" => 1
             }
           ]

    assert result["unresolved_internal_dependencies"] == 0
    assert Enum.any?(result["attempts"], &(&1["status"] == "frontend_normalization_failure"))
    assert result["unit_attempt"]["status"] == "pass"
  end

  @tag :tmp_dir
  test "shares a schema across modules in the same unit", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "point.ex", """
    defmodule Point do
      defstruct x: 0
    end
    """)

    write_source(tmp_dir, "reader.ex", """
    defmodule Reader do
      def x(%Point{x: value}), do: value
    end
    """)

    result = CorpusCompileLink.run(tmp_dir)

    assert result["status"] == "pass"
    assert result["modules"] == 2
    assert result["unit_attempt"]["status"] == "pass"
  end

  @tag :tmp_dir
  test "reports a failed unit as blocked with a bounded diagnostic", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "unsupported.ex", """
    defmodule Unsupported do
      def zip(left, right), do: Enum.zip(left, right)
    end
    """)

    result = CorpusCompileLink.run(tmp_dir)

    assert result["status"] == "blocked"
    assert result["unit_attempt"]["status"] == "frontend_normalization_failure"
    assert result["reason"] == "unsupported_stdlib_call"
    assert result["unit_attempt"]["diagnostic"] =~ "Enum.zip"
    assert byte_size(result["unit_attempt"]["diagnostic"]) <= 512
  end

  @tag :tmp_dir
  test "excludes source-proven compile-time providers from the runtime unit", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "provider.ex", """
    defmodule Fixture.Provider do
      def build(value), do: Enum.zip(value, value)
    end
    """)

    write_source(tmp_dir, "consumer.ex", """
    defmodule Fixture.Consumer do
      defmacro generated(value), do: Fixture.Provider.build(value)
      def main(), do: 42
    end
    """)

    result = CorpusCompileLink.run(tmp_dir)

    assert result["unit_attempt"]["status"] == "pass"

    assert result["runtime_slice"] == %{
             "removed_definition_count" => 1,
             "removed_definitions" => [
               %{"module" => "Fixture.Provider", "function" => "build", "arity" => 1}
             ]
           }
  end

  @tag :tmp_dir
  test "excludes dead private compile-time helpers from the runtime unit", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "dead_helper.ex", """
    defmodule DeadHelper do
      def value(), do: 42
      defp compile_time_only(left, right), do: Enum.zip(left, right)
    end
    """)

    result = CorpusCompileLink.run(tmp_dir)

    assert result["status"] == "pass"
    assert result["unit_attempt"]["status"] == "pass"
    assert hd(result["attempts"])["reason_class"] == "unsupported_stdlib_call"
  end

  @tag :tmp_dir
  test "retains private helpers reachable from a public definition", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "reachable_helper.ex", """
    defmodule ReachableHelper do
      def value(input), do: twice(input)
      defp twice(input), do: input * 2
    end
    """)

    assert %{"status" => "pass", "unit_attempt" => %{"status" => "pass"}} =
             CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "qualifies private function captures selected at runtime", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "captured_private.ex", """
    defmodule CapturedPrivate do
      def apply_selected(kind, value) do
        selected =
          case kind do
            :increment -> &increment/1
            :double -> &double/1
          end

        selected.(value)
      end

      defp increment(value), do: value + 1
      defp double(value), do: value * 2
    end
    """)

    assert %{"status" => "pass", "unit_attempt" => %{"status" => "pass"}} =
             CorpusCompileLink.run(tmp_dir)
  end

  defp write_source(root, name, contents) do
    lib = Path.join(root, "lib")
    File.mkdir_p!(lib)
    File.write!(Path.join(lib, name), contents)
  end
end
