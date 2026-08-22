defmodule Batata.Frontend.ProtocolAndClosureTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend
  alias Batata.Lift.Error
  alias Beaver.MLIR.Context

  test "normalizes defimpl into protocol implementation module snapshot" do
    source = """
    defimpl String.Chars, for: Integer do
      def to_string(term) do
        Integer.to_string(term)
      end
    end
    """

    mod = Frontend.from_source(source)
    assert mod.name == :"Elixir.String.Chars.Integer"
    assert length(mod.definitions) == 1
    assert hd(mod.definitions).name == :to_string
    assert hd(mod.definitions).arity == 1
    assert mod.unsupported == []
  end

  test "expands defimpl target lists into distinct implementation modules" do
    source = """
    defimpl String.Chars, for: [Integer, Float] do
      def to_string(term), do: term
    end
    """

    modules = Frontend.from_source(source)

    assert Enum.map(modules, & &1.name) == [
             :"Elixir.String.Chars.Integer",
             :"Elixir.String.Chars.Float"
           ]

    assert Enum.all?(modules, &(&1.unsupported == []))
  end

  test "substitutes implicit defimpl attributes per implementation" do
    modules =
      Frontend.from_source("""
      defimpl Sample.Encoder, for: [Date, Time] do
        def attributes(), do: {@protocol, @for}
        def encode(value), do: @protocol.encode(value, @for)
      end
      """)

    assert Enum.map(modules, fn module ->
             attributes = Enum.find(module.definitions, &(&1.name == :attributes))
             encode = Enum.find(module.definitions, &(&1.name == :encode))

             {module.name, hd(attributes.clauses).body_ast,
              Macro.to_string(hd(encode.clauses).body_ast)}
           end) == [
             {Sample.Encoder.Date, {Sample.Encoder, Date}, "Sample.Encoder.encode(value, Date)"},
             {Sample.Encoder.Time, {Sample.Encoder, Time}, "Sample.Encoder.encode(value, Time)"}
           ]
  end

  test "does not leak implicit defimpl attributes into nested lexical modules" do
    module =
      Frontend.from_source("""
      defimpl Sample.Encoder, for: Any do
        def attributes(), do: {@protocol, @for}

        defmodule Nested do
          def attributes(), do: {@protocol, @for}
        end
      end
      """)

    attributes = Enum.find(module.definitions, &(&1.name == :attributes))
    assert hd(attributes.clauses).body_ast == {Sample.Encoder, Any}

    assert [%Frontend.UnsupportedForm{reason: :nested_defmodule, form: nested}] =
             module.unsupported

    assert Macro.to_string(nested) =~ "{@protocol, @for}"
  end

  test "normalizes protocol declarations separately from implementations" do
    source = """
    defprotocol Printable do
      @moduledoc false
      @fallback_to_any true
      @spec print(term) :: binary
      def print(term)
    end

    defimpl Printable, for: Integer do
      def print(term), do: Integer.to_string(term)
    end
    """

    [protocol, implementation] = Frontend.from_source(source)
    assert protocol.name == Printable
    assert Enum.map(protocol.definitions, &{&1.name, &1.arity}) == [print: 1]
    assert protocol.protocol_options == %{fallback_to_any: true}
    assert protocol.unsupported == []
    assert implementation.name == Printable.Integer
  end

  test "keeps invalid protocol fallback metadata visible" do
    protocol =
      Frontend.from_source("""
      defprotocol InvalidFallback do
        @fallback_to_any :sometimes
        def value(term)
      end
      """)

    assert protocol.protocol_options == %{}
    assert [%Frontend.UnsupportedForm{reason: :module_attribute}] = protocol.unsupported
  end

  test "drops documentation and compiler metadata at the canonical boundary" do
    source = """
    defmodule MetadataDemo do
      @moduledoc false
      @doc "identity"
      @spec identity(term) :: term
      @compile {:inline, identity: 1}
      def identity(term), do: term
    end
    """

    snapshot = Frontend.from_source(source)
    assert snapshot.unsupported == []
    assert Enum.map(snapshot.definitions, &{&1.name, &1.arity}) == [identity: 1]
  end

  test "keeps external dynamic closure dispatch fail-closed" do
    source = """
    defmodule CallerClosure do
      def apply_it(fun, value) do
        fun.(value)
      end

      def main() do
        0
      end
    end
    """

    snapshot = Frontend.from_source(source)

    assert_raise Error, ~r/dynamic_apply_without_local_dispatch/, fn ->
      Batata.compile(snapshot, Context.create())
    end
  end
end
