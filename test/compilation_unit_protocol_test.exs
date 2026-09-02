defmodule Batata.CompilationUnitProtocolTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata.{CompilationUnit, Frontend}

  defmodule StaticRaisedError do
    defexception signal: :default, reason: nil

    @impl true
    def message(error), do: "#{error.signal}: #{error.reason}"
  end

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

  test "rescues and dispatches source exception messages inside a qualified unit", %{ctx: ctx} do
    source = """
    defmodule Unit.MessageError do
      defexception [:value]
      def message(%{value: value}), do: "message: " <> value
    end

    defmodule Unit.MessageOracle do
      def main() do
        try do
          raise %Unit.MessageError{value: "boom"}
        rescue
          error in Unit.MessageError -> Exception.message(error)
        end
      end
    end
    """

    unit =
      source
      |> Frontend.from_source()
      |> CompilationUnit.build(entry: {Unit.MessageOracle, :main, 0})

    assert Batata.execute(unit, ctx) == "message: boom"
  end

  test "renders a nil exception field inside a qualified unit", %{ctx: ctx} do
    source = ~S'''
    defmodule Unit.OptionalSignalError do
      defexception [:signal, :reason]

      def message(%{signal: signal, reason: reason}) do
        reason = reason && ": " <> reason
        "#{signal}#{reason}"
      end
    end

    defmodule Unit.OptionalSignalOracle do
      def main() do
        try do
          raise Unit.OptionalSignalError, reason: "invalid input"
        rescue
          error in Unit.OptionalSignalError -> Exception.message(error)
        end
      end
    end
    '''

    unit =
      source
      |> Frontend.from_source()
      |> CompilationUnit.build(entry: {Unit.OptionalSignalOracle, :main, 0})

    assert Batata.execute(unit, ctx) == ": invalid input"
  end

  test "raises a static application exception from runtime keyword attributes", %{ctx: ctx} do
    source = """
    defmodule Batata.CompilationUnitProtocolTest.StaticRaisedError do
      defexception signal: :default, reason: nil
      def message(error), do: Atom.to_string(error.signal) <> ": " <> error.reason
    end

    defmodule Unit.StaticRaiseOracle do
      alias Batata.CompilationUnitProtocolTest.StaticRaisedError, as: Error

      def main() do
        attributes = [signal: :invalid_operation, reason: "runtime attributes"]
        raise Error, attributes
      end
    end
    """

    unit =
      source
      |> Frontend.from_source()
      |> CompilationUnit.build(entry: {Unit.StaticRaiseOracle, :main, 0})

    error =
      assert_raise StaticRaisedError, "invalid_operation: runtime attributes", fn ->
        Batata.execute(unit, ctx)
      end

    assert error.signal == :invalid_operation
    assert error.reason == "runtime attributes"
  end

  test "rejects attributes outside a static exception schema", %{ctx: ctx} do
    source = """
    defmodule Batata.CompilationUnitProtocolTest.StaticRaisedError do
      defexception signal: :default, reason: nil
    end

    defmodule Unit.InvalidStaticRaiseOracle do
      def main() do
        attributes = [signal: :invalid_operation, unknown: "not declared"]
        raise Batata.CompilationUnitProtocolTest.StaticRaisedError, attributes
      end
    end
    """

    unit =
      source
      |> Frontend.from_source()
      |> CompilationUnit.build(entry: {Unit.InvalidStaticRaiseOracle, :main, 0})

    assert_raise ArgumentError,
                 "unknown exception attributes for " <>
                   "Batata.CompilationUnitProtocolTest.StaticRaisedError",
                 fn -> Batata.execute(unit, ctx) end
  end

  test "formats a rescued Protocol.UndefinedError inside a qualified unit", %{ctx: ctx} do
    source = """
    defprotocol Unit.MissingProtocol do
      def render(value)
    end

    defmodule Unit.ProtocolMessageOracle do
      def main() do
        try do
          raise Protocol.UndefinedError,
            protocol: Unit.MissingProtocol,
            value: :missing,
            description: "missing"
        rescue
          error in Protocol.UndefinedError -> Exception.message(error)
        end
      end
    end
    """

    unit =
      source
      |> Frontend.from_source()
      |> List.wrap()
      |> CompilationUnit.build(entry: {Unit.ProtocolMessageOracle, :main, 0})

    expected =
      "protocol Unit.MissingProtocol not implemented for Atom, missing\n\n" <>
        "Got value:\n\n    :missing\n"

    assert Batata.execute(unit, ctx) == expected
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
