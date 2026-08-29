defmodule Batata.CompilationUnitProtocolTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata.{CompilationUnit, Frontend}

  test "dispatches generated protocols across builtins, structs, maps, and Any", %{ctx: ctx} do
    source = """
    defprotocol RenderValue do
      @fallback_to_any true
      def render(value)
    end

    defimpl RenderValue, for: Integer do
      def render(value), do: value + 1
    end

    defimpl RenderValue, for: Map do
      def render(_value), do: 20
    end

    defmodule RenderedStruct do
      defstruct [:value]
    end

    defimpl RenderValue, for: RenderedStruct do
      def render(_value), do: 30
    end

    defimpl RenderValue, for: Any do
      def render(_value), do: 40
    end

    defmodule ProtocolOracle do
      def main() do
        {
          RenderValue.render(1),
          RenderValue.render(%{}),
          RenderValue.render(%RenderedStruct{value: 1}),
          RenderValue.render(%{__struct__: UnknownStruct}),
          RenderValue.render(:atom)
        }
      end
    end
    """

    unit =
      source
      |> Frontend.from_source()
      |> CompilationUnit.build(entry: {ProtocolOracle, :main, 0})

    refute inspect(unit) =~ "__protocol_dispatch__"
    assert Batata.execute(unit, ctx) == {2, 20, 30, 40, 40}
  end

  test "rejects an implementation whose runtime predicate is unavailable" do
    modules =
      Frontend.from_source("""
      defprotocol Callable do
        def call(value)
      end

      defimpl Callable, for: Function do
        def call(_value), do: :function
      end
      """)

    assert_raise ArgumentError, ~r/Function.*unsupported runtime predicate/, fn ->
      CompilationUnit.build(modules)
    end
  end

  test "raises Protocol.UndefinedError when no implementation or Any fallback matches", %{
    ctx: ctx
  } do
    source = """
    defprotocol StrictValue do
      def render(value)
    end

    defimpl StrictValue, for: Integer do
      def render(value), do: value
    end

    defmodule StrictProtocolOracle do
      def main(), do: StrictValue.render(:missing)
    end
    """

    unit =
      source
      |> Frontend.from_source()
      |> CompilationUnit.build(entry: {StrictProtocolOracle, :main, 0})

    error =
      try do
        Batata.execute(unit, ctx)
      rescue
        error in Protocol.UndefinedError -> error
      end

    assert %Protocol.UndefinedError{} = error
    assert error.protocol == StrictValue
    assert error.value == :missing
  end
end
