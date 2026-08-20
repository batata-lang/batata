defmodule Batata.Frontend.ModuleEnvironmentTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend
  alias Batata.Frontend.ModuleEnvironment

  test "substitutes sequential literal attributes and consumes bounded imports" do
    snapshot =
      Frontend.from_source("""
      defmodule Sample do
        import Bitwise
        import Kernel, except: [div: 2]

        @base 3
        @mask @base

        def div(left, right), do: left - right
        def mask(value), do: (value &&& @mask) <<< 1
      end
      """)

    assert snapshot.unsupported == []

    mask =
      Enum.find(snapshot.definitions, fn definition ->
        definition.name == :mask and definition.arity == 1
      end)

    assert Macro.to_string(hd(mask.clauses).body_ast) == "(value &&& 3) <<< 1"
  end

  test "uses the explicit default for compile_env without reading host configuration" do
    snapshot =
      Frontend.from_source("""
      defmodule Sample do
        @limit Application.compile_env(:sample, :limit, 1024)
        def limit(), do: @limit
      end
      """)

    assert snapshot.unsupported == []

    assert [%Frontend.Definition{clauses: [%Frontend.Clause{body_ast: 1024}]}] =
             snapshot.definitions
  end

  test "keeps unused and unsupported attributes visible" do
    snapshot =
      Frontend.from_source("""
      defmodule Sample do
        @protocol_option true
        @dynamic System.unique_integer()
        def dynamic(), do: @dynamic
      end
      """)

    assert Enum.map(snapshot.unsupported, & &1.reason) == [
             :module_attribute,
             :module_attribute
           ]

    assert [%Frontend.Definition{clauses: [%Frontend.Clause{body_ast: {:@, _, _}}]}] =
             snapshot.definitions
  end

  test "does not leak attributes into nested modules" do
    {:ok, ast} =
      Code.string_to_quoted("""
      defmodule Outer do
        @value 1
        def value(), do: @value

        defmodule Inner do
          def value(), do: @value
        end
      end
      """)

    expanded = ModuleEnvironment.expand(ast)
    rendered = Macro.to_string(expanded)

    assert rendered =~ "def value() do\n    1\n  end"
    assert rendered =~ "defmodule Inner"
    assert rendered =~ "@value"
  end

  test "leaves imports outside the explicit module and option allowlists unsupported" do
    enum = Frontend.from_source("defmodule Sample do\nimport Enum\ndef ok(), do: true\nend")

    bitwise =
      Frontend.from_source(
        "defmodule Sample do\nimport Bitwise, only: [unknown: 2]\ndef ok(), do: true\nend"
      )

    assert [%Frontend.UnsupportedForm{reason: :import}] = enum.unsupported
    assert [%Frontend.UnsupportedForm{reason: :import}] = bitwise.unsupported
  end
end
