defmodule Batata.Frontend.MetadataMacroExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend

  test "consumes imported macros proven to emit metadata only" do
    macro_source = """
    defmodule Docs do
      defmacro since(version) do
        if Version.match?(System.version(), ">= 1.7.0") do
          quote do
            @doc since: unquote(version)
          end
        end
      end
    end
    """

    consumer_source = """
    defmodule Sample do
      import Docs
      since("1.2.3")
      def value(), do: 1
    end
    """

    [docs, sample] = Frontend.from_sources([macro_source, consumer_source])

    assert docs.unsupported == []
    assert sample.unsupported == []
    assert Enum.map(sample.definitions, &{&1.name, &1.arity}) == [value: 0]

    isolated = Frontend.from_source(consumer_source)
    assert Enum.map(isolated.unsupported, & &1.reason) == [:import, :unknown_form]
  end

  test "keeps macros with runtime output and their imports visible" do
    macro_source = """
    defmodule RuntimeMacros do
      defmacro increment(value) do
        quote do
          unquote(value) + 1
        end
      end
    end
    """

    consumer_source = """
    defmodule Sample do
      import RuntimeMacros
      increment(1)
      def value(), do: 1
    end
    """

    [macros, sample] = Frontend.from_sources([macro_source, consumer_source])

    assert [%Frontend.UnsupportedForm{reason: :unknown_form}] = macros.unsupported
    assert Enum.map(sample.unsupported, & &1.reason) == [:import, :unknown_form]
  end
end
