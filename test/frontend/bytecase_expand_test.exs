defmodule Batata.Frontend.BytecaseExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend

  @provider """
  defmodule DispatchBuilder do
    defmacro dispatch(value, do: clauses) do
      {ranges, default, literals} = clauses_to_ranges(clauses)
      table = jump_table(ranges, default)

      quote do
        case unquote(value) do
          unquote(jump_table_to_clauses(table, literals))
        end
      end
    end

    defmacro dispatch(value, maximum, do: clauses) do
      {ranges, default, literals} = clauses_to_ranges(clauses)
      table = jump_table(ranges, default, maximum)

      quote do
        case unquote(value) do
          unquote(jump_table_to_clauses(table, literals))
        end
      end
    end
  end
  """

  test "discovers and expands an imported binary dispatch macro" do
    consumer = """
    defmodule DispatchConsumer do
      import DispatchBuilder, only: [dispatch: 2, dispatch: 3]

      def main() do
        dispatch "ax" do
          _ in ~c"ab", _rest -> 11
          _, _rest -> 0
          <<>> -> -1
        end
      end
    end
    """

    modules = Frontend.from_sources([@provider, consumer])
    provider = Enum.find(modules, &(&1.name == DispatchBuilder))
    consumer = Enum.find(modules, &(&1.name == DispatchConsumer))

    assert provider.unsupported == []
    assert consumer.unsupported == []

    main = Enum.find(consumer.definitions, &(&1.name == :main))
    assert [%Frontend.Clause{body_ast: body}] = main.clauses
    assert {11, []} = Code.eval_quoted(body)
  end

  test "bounds the generated default byte clause for explicit table sizes" do
    consumer = """
    defmodule BoundedDispatch do
      import DispatchBuilder, only: [dispatch: 3]

      def classify(data) do
        dispatch data, 128 do
          _ in ~c"a", _rest -> :ascii
          _, _rest -> :other_ascii
          <<char::utf8, _rest::bits>> -> char
          <<>> -> :empty
        end
      end
    end
    """

    snapshot =
      [@provider, consumer]
      |> Frontend.from_sources()
      |> Enum.find(&(&1.name == BoundedDispatch))

    assert snapshot.unsupported == []
    definition = Enum.find(snapshot.definitions, &(&1.name == :classify))
    assert [%Frontend.Clause{body_ast: {:case, _, [_data, [do: clauses]]}}] = definition.clauses
    assert Enum.any?(clauses, &(Macro.to_string(&1) =~ "<= 127"))
  end

  test "does not infer dispatch semantics from a macro name alone" do
    provider = """
    defmodule UnknownBuilder do
      defmacro dispatch(value, do: _clauses), do: value
    end
    """

    consumer = """
    defmodule UnknownConsumer do
      import UnknownBuilder, only: [dispatch: 2]
      def value(data), do: dispatch(data, do: [])
    end
    """

    modules = Frontend.from_sources([provider, consumer])
    provider = Enum.find(modules, &(&1.name == UnknownBuilder))
    consumer = Enum.find(modules, &(&1.name == UnknownConsumer))

    assert Enum.count(provider.unsupported) == 1
    assert Enum.count(consumer.unsupported) == 1
  end
end
