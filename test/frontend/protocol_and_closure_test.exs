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

  test "rejects unsupported defimpl target lists instead of treating them as Any" do
    source = """
    defimpl String.Chars, for: [Integer, Float] do
      def to_string(term), do: term
    end
    """

    assert_raise ArgumentError, ~r/unsupported defimpl target/, fn ->
      Frontend.from_source(source)
    end
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
