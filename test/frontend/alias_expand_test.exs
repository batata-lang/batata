defmodule Batata.Frontend.AliasExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend
  alias Batata.Frontend.AliasExpand

  test "expands supported declarations in lexical order and removes them" do
    source = """
    defmodule Sample do
      def before(), do: Dec.value()
      alias First.Dependency, as: Dec
      def first(), do: Dec.value()
      alias Second.Dependency, as: Dec
      def second(), do: Dec.value()
      alias Group.{Left, Right}
      def grouped(), do: {Left.value(), Right.value(), __MODULE__}
    end
    """

    expanded = source |> Code.string_to_quoted!() |> AliasExpand.expand() |> Macro.to_string()

    assert expanded =~ "def before() do\n    Dec.value()"
    assert expanded =~ "First.Dependency.value()"
    assert expanded =~ "Second.Dependency.value()"
    assert expanded =~ "Group.Left.value()"
    assert expanded =~ "Group.Right.value()"
    assert expanded =~ "Sample"
    refute expanded =~ "alias "
  end

  test "keeps unsupported aliases and isolates nested module scopes" do
    source = """
    defmodule Outer do
      alias Dependency, warn: false

      defmodule Inner do
        alias Nested.Dependency, as: Dep
        def value(), do: Dep.value()
      end
    end
    """

    expanded = source |> Code.string_to_quoted!() |> AliasExpand.expand() |> Macro.to_string()

    assert expanded =~ "alias Dependency, warn: false"
    assert expanded =~ "alias Nested.Dependency, as: Dep"
    assert expanded =~ "Dep.value()"
  end

  test "feeds expanded aliases through the compiler frontend" do
    snapshot =
      Frontend.from_source("""
      defmodule Sample do
        alias Jason.Decoder
        def parse(input), do: Decoder.parse(input)
      end
      """)

    assert snapshot.unsupported == []

    assert [%Frontend.Definition{clauses: [%Frontend.Clause{body_ast: body}]}] =
             snapshot.definitions

    assert Macro.to_string(body) == "Jason.Decoder.parse(input)"
  end

  @tag :tmp_dir
  test "preserves BEAM behaviour for a self-contained fixture", %{tmp_dir: tmp_dir} do
    source = """
    defmodule Fixture.Dependency do
      def value(), do: 7
    end

    defmodule Fixture.Sample do
      alias Fixture.Dependency, as: Dep
      def value(), do: Dep.value()
    end

    IO.write(Fixture.Sample.value())
    """

    {:ok, ast} = Code.string_to_quoted(source)
    {:__block__, metadata, [dependency, sample, output]} = ast
    expanded = {:__block__, metadata, [dependency, AliasExpand.expand(sample), output]}

    original_path = Path.join(tmp_dir, "original.exs")
    expanded_path = Path.join(tmp_dir, "expanded.exs")
    File.write!(original_path, source)
    File.write!(expanded_path, Macro.to_string(expanded))

    assert {"7", 0} = System.cmd("elixir", [original_path], stderr_to_stdout: true)
    assert {"7", 0} = System.cmd("elixir", [expanded_path], stderr_to_stdout: true)
  end
end
