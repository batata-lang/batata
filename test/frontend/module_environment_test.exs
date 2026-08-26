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

    assert Macro.to_string(hd(mask.clauses).body_ast) ==
             "Bitwise.<<<(Bitwise.&&&(value, 3), 1)"
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

  test "attributes only imported Bitwise signatures and honors except" do
    only =
      Frontend.from_source("""
      defmodule OnlyShift do
        import Bitwise, only: [>>>: 2]
        def selected(value), do: value >>> 2
        def excluded(value), do: value <<< 2
      end
      """)

    selected = Enum.find(only.definitions, &(&1.name == :selected))
    excluded = Enum.find(only.definitions, &(&1.name == :excluded))

    assert Macro.to_string(hd(selected.clauses).body_ast) == "Bitwise.>>>(value, 2)"
    assert Macro.to_string(hd(excluded.clauses).body_ast) == "value <<< 2"

    except =
      Frontend.from_source("""
      defmodule ExceptLeftShift do
        import Bitwise, except: [<<<: 2]
        def selected(value), do: value >>> 2
        def excluded(value), do: value <<< 2
      end
      """)

    selected = Enum.find(except.definitions, &(&1.name == :selected))
    excluded = Enum.find(except.definitions, &(&1.name == :excluded))

    assert Macro.to_string(hd(selected.clauses).body_ast) == "Bitwise.>>>(value, 2)"
    assert Macro.to_string(hd(excluded.clauses).body_ast) == "value <<< 2"
  end

  test "preserves module-local definitions which overlap Bitwise imports" do
    snapshot =
      Frontend.from_source("""
      defmodule LocalShift do
        import Bitwise
        def left >>> right, do: left + right
        def shift(value), do: value >>> 2
      end
      """)

    shift = Enum.find(snapshot.definitions, &(&1.name == :shift))
    assert Macro.to_string(hd(shift.clauses).body_ast) == "value >>> 2"
  end
end
