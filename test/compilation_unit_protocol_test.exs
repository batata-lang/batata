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

  test "dispatches a statically derived implementation across source files", %{ctx: ctx} do
    provider = """
    defprotocol Sample.Encoder do
      @fallback_to_any true
      def encode(value, opts)
    end

    defmodule Sample.Encode do
      def value(_value, _escape, _encode_map), do: "encoded"
    end

    defimpl Sample.Encoder, for: Any do
      defmacro __deriving__(module, struct, opts) do
        fields = fields_to_encode(struct, opts)
        kv = Enum.map(fields, &{&1, generated_var(&1)})
        iodata = Sample.Codegen.build_kv_iodata(kv, [])

        quote do
          defimpl Sample.Encoder, for: unquote(module) do
            def encode(%{unquote_splicing(kv)}, opts), do: {opts, unquote(iodata)}
          end
        end
      end

      def encode(_value, _opts), do: :fallback
    end
    """

    consumer = """
    defmodule Sample.Fixture do
      @derive {Sample.Encoder, only: [:visible]}
      defstruct [:visible, :hidden]
    end

    defmodule Sample.Oracle do
      def main(), do: Sample.Encoder.encode(%Sample.Fixture{visible: 7, hidden: 9}, {nil, nil})
    end
    """

    modules = Frontend.from_sources([provider, consumer])
    unit = CompilationUnit.build(modules, entry: {Sample.Oracle, :main, 0})

    assert Batata.execute(unit, ctx) == ["{\"visible\":", "encoded", "}"]
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

  test "materializes function-clause failures from compilation units", %{ctx: ctx} do
    source = """
    defmodule UnitFunctionClause do
      def accept(:ok), do: :ok
    end

    defmodule UnitFunctionClauseOracle do
      def main(), do: UnitFunctionClause.accept(:missing)
    end
    """

    unit =
      source
      |> Frontend.from_source()
      |> CompilationUnit.build(entry: {UnitFunctionClauseOracle, :main, 0})

    error = assert_raise FunctionClauseError, fn -> Batata.execute(unit, ctx) end

    assert error.module == Batata.CompilationUnit
    assert error.arity == 1
    assert error.args == [:missing]
  end
end
