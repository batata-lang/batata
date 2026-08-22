defmodule Batata.Frontend.MetaprogrammingExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend
  alias Batata.Frontend.MetaprogrammingExpand
  alias Beaver.MLIR.Context

  test "expands top-level for generator into function definitions" do
    source = """
    defmodule GeneratorDemo do
      for type <- [Date, Time, NaiveDateTime] do
        def encode(unquote(type), value), do: value
      end
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.unsupported == []

    names_arities = Enum.map(snapshot.definitions, &{&1.name, &1.arity})
    assert names_arities == [encode: 2, encode: 2, encode: 2]
    assert length(snapshot.definitions) == 3
  end

  test "expands top-level if true branch and drops false branch" do
    source = """
    defmodule ConditionalDemo do
      if true do
        def active(), do: 1
      else
        def inactive(), do: 0
      end
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.unsupported == []
    assert Enum.map(snapshot.definitions, & &1.name) == [:active]
  end

  test "expands Version.compare compile-time condition" do
    source = """
    defmodule VersionDemo do
      if Version.compare(System.version(), "1.0.0") == :gt do
        def modern(), do: :ok
      else
        def legacy(), do: :old
      end
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.unsupported == []
    assert Enum.map(snapshot.definitions, & &1.name) == [:modern]
  end

  test "selects deterministic optional-module and function capability branches" do
    source = """
    defmodule CapabilityDemo do
      if Code.ensure_loaded?(Optional.Dependency) do
        def optional(), do: :present
      else
        def optional(), do: :absent
      end

      if function_exported?(Application, :compile_env, 3) do
        def compile_env(), do: :supported
      end
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.unsupported == []
    assert Enum.map(snapshot.definitions, & &1.name) == [:optional, :compile_env]
  end

  test "end-to-end executes function generated from top-level for loop" do
    source = """
    defmodule Calc do
      for op <- [:add, :sub] do
        def run(unquote(op), a) do
          a + 10
        end
      end

      def main() do
        run(:add, 20)
      end
    end
    """

    assert 30 == Batata.execute(source, Context.create())
  end

  test "expands a literal range without host evaluation" do
    source = """
    defmodule RangeDemo do
      for depth <- 1..3 do
        def depth(unquote(depth)), do: unquote(depth)
      end
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.unsupported == []
    assert Enum.map(snapshot.definitions, & &1.name) == [:depth, :depth, :depth]
  end

  test "structurally decodes tuple and map collection literals" do
    source = """
    defmodule LiteralDataDemo do
      for item <- [{:tuple, 1}, %{kind: :map}] do
        def item(unquote(Macro.escape(item))), do: :ok
      end
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.unsupported == []
    assert length(snapshot.definitions) == 2
  end

  test "expands a bounded reduce definition generator and its final binding" do
    snapshot =
      Frontend.from_source("""
      defmodule ReduceDemo do
        maximum =
          Enum.reduce(0..2, 1, fn index, acc ->
            def power(unquote(index)), do: unquote(acc)
            def base?(unquote(acc)), do: true
            acc * 10
          end)

        def maximum(), do: unquote(maximum)
      end
      """)

    assert snapshot.unsupported == []
    assert Enum.count(snapshot.definitions, &(&1.name == :power)) == 3
    assert Enum.count(snapshot.definitions, &(&1.name == :base?)) == 3

    maximum = Enum.find(snapshot.definitions, &(&1.name == :maximum))
    assert [%Frontend.Clause{body_ast: 1000}] = maximum.clauses
  end

  test "carries bounded structural bindings into later generators" do
    snapshot =
      Frontend.from_source("""
      defmodule BindingDemo do
        zipped = Enum.zip(~c"ab", [:one, :two])
        entries = [{0, :zero} | zipped]

        for entry <- entries do
          def entry(unquote(Macro.escape(entry))), do: :ok
        end
      end
      """)

    assert snapshot.unsupported == []
    assert Enum.count(snapshot.definitions, &(&1.name == :entry)) == 3
  end

  test "selects the successful branch of an allowlisted capability probe" do
    snapshot =
      Frontend.from_source("""
      defmodule ProbeDemo do
        available =
          try do
            :erlang.float_to_binary(1.0, [:short])
          catch
            _, _ -> false
          else
            _ -> true
          end

        if available do
          def selected(), do: :supported
        else
          def selected(), do: :fallback
        end
      end
      """)

    assert snapshot.unsupported == []
    assert [%Frontend.Clause{body_ast: :supported}] = hd(snapshot.definitions).clauses
  end

  test "discovers an array-backed table builder and expands multi-clause generators" do
    builder = """
    defmodule TableBuilder do
      def build(ranges, default) do
        ranges
        |> ranges_to_orddict()
        |> :array.from_orddict(default)
        |> :array.to_orddict()
      end

      defp ranges_to_orddict(ranges), do: ranges
    end
    """

    consumer = """
    defmodule TableConsumer do
      ranges = [{0..1, :taken}]
      table = TableBuilder.build(ranges, :fallback)

      Enum.map(table, fn
        {index, :taken} ->
          def value(unquote(index)), do: :taken

        {index, :fallback} ->
          def value(unquote(index)), do: :fallback
      end)
    end
    """

    modules = Frontend.from_sources([builder, consumer])
    snapshot = Enum.find(modules, &(&1.name == TableConsumer))

    assert snapshot.unsupported == []
    assert Enum.count(snapshot.definitions, &(&1.name == :value)) == 2
  end

  test "evaluates bounded binary expressions in generated unquotes" do
    snapshot =
      Frontend.from_source("""
      defmodule BinaryGenerator do
        Enum.each([{?/, ?/}, {?b, ?b}], fn {byte, char} when is_integer(char) ->
          def escape(unquote(byte)), do: unquote(<<?\\\\, char>>)
        end)

        def main() do
          case {escape(?/), escape(?b)} do
            {<<?\\\\, ?/>>, <<?\\\\, ?b>>} -> 1
            _ -> 0
          end
        end
      end
      """)

    escape_bodies =
      snapshot.definitions
      |> Enum.filter(&(&1.name == :escape))
      |> Enum.flat_map(& &1.clauses)
      |> Enum.map(& &1.body_ast)

    assert escape_bodies == [<<?\\, ?/>>, <<?\\, ?b>>]
    assert snapshot.unsupported == []
  end

  test "evaluates explicit binary segments in generated unquotes" do
    snapshot =
      Frontend.from_source("""
      defmodule BinarySegmentGenerator do
        Enum.each([{"\\\\", ?/}], fn {prefix, char} ->
          def escape(), do: unquote(<<prefix::binary, char>>)
        end)
      end
      """)

    assert [%Frontend.Definition{clauses: [%Frontend.Clause{body_ast: <<?\\, ?/>>}]}] =
             snapshot.definitions
  end

  test "does not evaluate unsupported generated bitstring segments" do
    ast =
      Code.string_to_quoted!("""
      defmodule UnsupportedBinaryGenerator do
        for value <- [1] do
          def value(), do: unquote(<<value::16>>)
        end
      end
      """)

    expanded = MetaprogrammingExpand.expand(ast)
    assert Macro.to_string(expanded) =~ "unquote(<<value::16>>)"
  end

  test "executes functions generated from bounded binary expressions" do
    source = """
    defmodule BinaryGeneratorExecution do
      Enum.each([{?/, ?/}, {?b, ?b}], fn {byte, char} when is_integer(char) ->
        defp escape(unquote(byte)), do: unquote(<<?\\\\, char>>)
      end)

      def main() do
        case {escape(?/), escape(?b)} do
          {<<?\\\\, ?/>>, <<?\\\\, ?b>>} -> 1
          _ -> 0
        end
      end
    end
    """

    assert 1 == Batata.execute(source, Context.create())
  end

  test "does not infer table semantics from an undiscovered function name" do
    snapshot =
      Frontend.from_source("""
      defmodule UnknownTable do
        table = Other.jump_table([{0, :value}], :fallback)
        Enum.map(table, fn {index, value} ->
          def value(unquote(index)), do: unquote(value)
        end)
      end
      """)

    assert Enum.count(snapshot.unsupported) == 2
  end

  test "keeps reduce generators outside the structural allowlist visible" do
    snapshot =
      Frontend.from_source("""
      defmodule ReduceDemo do
        result =
          Enum.reduce(1..3, 0, fn item, acc ->
            def generated(unquote(item)), do: unquote(acc)
            IO.puts(item)
          end)

        def result(), do: unquote(result)
      end
      """)

    assert [%Frontend.UnsupportedForm{form: {:=, _, _}}] = snapshot.unsupported
  end

  test "leaves unsupported generators unchanged, including metadata" do
    ast =
      {:defmodule, [line: 1],
       [
         {:__aliases__, [line: 1], [:UnsupportedGenerator]},
         [
           do:
             {:for, [line: 3],
              [
                {:<-, [line: 3], [{:item, [line: 3], nil}, {:items, [line: 3], nil}]},
                [do: {:def, [line: 4], [{:generated, [line: 4], []}, [do: 1]]}]
              ]}
         ]
       ]}

    assert MetaprogrammingExpand.expand(ast) == ast
  end

  test "leaves unsupported conditions unchanged, including metadata" do
    ast =
      {:defmodule, [line: 1],
       [
         {:__aliases__, [line: 1], [:UnsupportedCondition]},
         [
           do:
             {:if, [line: 3],
              [
                {:enabled?, [line: 3], nil},
                [do: {:def, [line: 4], [{:generated, [line: 4], []}, [do: 1]]}]
              ]}
         ]
       ]}

    assert MetaprogrammingExpand.expand(ast) == ast
  end

  test "does not evaluate calls in generator collections" do
    source = """
    defmodule UnsupportedCall do
      for item <- System.cmd("echo", ["not evaluated"]) do
        def generated(), do: unquote(item)
      end
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.definitions == []
    assert [%Frontend.UnsupportedForm{form: {:for, _, _}}] = snapshot.unsupported
  end
end
