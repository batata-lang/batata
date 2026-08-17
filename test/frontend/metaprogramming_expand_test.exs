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
