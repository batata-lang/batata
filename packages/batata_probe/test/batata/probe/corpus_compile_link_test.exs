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
  test "qualifies a piped call by its effective arity instead of a default wrapper", %{
    tmp_dir: tmp_dir
  } do
    write_source(tmp_dir, "formatter.ex", """
    defmodule Formatter do
      def render(input, opts \\\\ []), do: {input, opts}
      def call(input, opts), do: input |> render(opts)
    end
    """)

    assert %{"status" => "pass", "unit_attempt" => %{"status" => "pass"}} =
             CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "qualifies nested cross-module pipes by effective arity", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "formatter.ex", """
    defmodule Formatter do
      def render(input, _opts), do: input
    end
    """)

    write_source(tmp_dir, "caller.ex", """
    defmodule Caller do
      def call(input, opts) do
        input |> Formatter.render(opts) |> Formatter.render(opts)
      end
    end
    """)

    assert %{"status" => "pass", "unit_attempt" => %{"status" => "pass"}} =
             CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "keeps isolated attempt order stable when attempts run concurrently", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "alpha.ex", """
    defmodule Alpha do
      def value(), do: 1
    end
    """)

    write_source(tmp_dir, "beta.ex", """
    defmodule Beta do
      def value(), do: 2
    end
    """)

    result = CorpusCompileLink.run(tmp_dir, max_concurrency: 2)

    assert Enum.map(result["attempts"], & &1["module"]) == ["Alpha", "Beta"]
    assert result["unit_attempt"]["status"] == "pass"
  end

  test "rejects an invalid isolated attempt concurrency" do
    assert_raise ArgumentError, ~r/max_concurrency must be a positive integer/, fn ->
      CorpusCompileLink.run("unused", max_concurrency: 0)
    end
  end

  @tag :tmp_dir
  test "writes a bounded qualified profile without changing compile-link evidence", %{
    tmp_dir: tmp_dir
  } do
    write_source(tmp_dir, "profiled.ex", """
    defmodule Profiled do
      def value(), do: 42
    end
    """)

    output = Path.join(tmp_dir, "evidence/qualified-profile.json")

    result =
      CorpusCompileLink.run(tmp_dir,
        diagnose_isolated: false,
        profile_output: output
      )

    assert result["status"] == "pass"
    assert result["isolated_attempts"] == "omitted"
    assert result["attempts"] == []

    profile = output |> File.read!() |> JSON.decode!()
    assert profile["schema_version"] == 1
    assert profile["name"] == "qualified_multi_module_unit"
    assert profile["status"] == "ok"
    assert profile["duration_ns"] >= 0
    assert Enum.map(profile["stages"], & &1["name"]) == ~w(compile lower verify cleanup)

    compile = Enum.find(profile["stages"], &(&1["name"] == "compile"))

    assert Enum.map(compile["compilation"]["stages"], & &1["name"]) ==
             ~w(snapshot lift inline_scalar_calls expand_case verify memory_verify)

    lower = Enum.find(profile["stages"], &(&1["name"] == "lower"))
    assert lower["lowering"]["status"] == "ok"
    assert hd(lower["lowering"]["stages"])["conversion_profile"]["status"] == "ok"
  end

  test "rejects invalid diagnostic and profile options" do
    assert_raise ArgumentError, ~r/diagnose_isolated must be a boolean/, fn ->
      CorpusCompileLink.run("unused", diagnose_isolated: :sometimes)
    end

    assert_raise ArgumentError, ~r/profile_output must be a path/, fn ->
      CorpusCompileLink.run("unused", profile_output: 42)
    end
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

  @tag :tmp_dir
  test "qualifies calls inside Jason-shaped shorthand continuations", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "formatter.ex", """
    defmodule Formatter do
      def continuation(depth, empty, opts), do: &render(&1, &2, depth, empty, opts)
      defp render(input, output, depth, empty, opts), do: {input, output, depth, empty, opts}
    end
    """)

    assert %{"status" => "pass", "unit_attempt" => %{"status" => "pass"}} =
             CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "compiles Jason Formatter-shaped exhaustive cond clauses", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "formatter.ex", """
    defmodule Formatter do
      def render(byte, depth, empty) do
        cond do
          depth == :first -> {byte, 1}
          depth == 0 -> {[byte], 1}
          empty -> {[byte], depth + 1}
          true -> {byte, depth + 1}
        end
      end
    end
    """)

    assert %{"status" => "pass", "unit_attempt" => %{"status" => "pass"}} =
             CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "compiles Jason Encode-shaped literal charlist terminators", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "encode.ex", """
    defmodule Encode do
      def render() do
        {list_loop([], nil, nil), map_naive_loop([], nil, nil),
         map_strict_loop([], nil, nil, %{})}
      end

      defp list_loop([], _escape, _encode_map), do: ~c']'
      defp map_naive_loop([], _escape, _encode_map), do: ~c'}'
      defp map_strict_loop([], _escape, _encode_map, _visited), do: ~c'}'
    end
    """)

    assert %{"status" => "pass", "unit_attempt" => %{"status" => "pass"}} =
             CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "keeps imported raise out of qualified local symbols", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "raising.ex", """
    defmodule Raising do
      def unwrap(result) do
        case result do
          {:ok, value} -> value
          {:error, error} -> raise error
        end
      end

      def explicit(error), do: Kernel.raise(error)
    end
    """)

    assert %{"status" => "pass", "unit_attempt" => %{"status" => "pass"}} =
             CorpusCompileLink.run(tmp_dir)
  end

  @tag :tmp_dir
  test "compiles Jason Encoder-shaped raise/2 boundaries", %{tmp_dir: tmp_dir} do
    write_source(tmp_dir, "encoder.ex", """
    defimpl Encoder, for: Any do
      def encode(value, _opts) do
        raise(Protocol.UndefinedError,
          protocol: Encoder,
          value: value,
          description: "cannot encode value"
        )
      end
    end

    defmodule Decoder do
      def argument_error(message), do: raise(ArgumentError, message)
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
