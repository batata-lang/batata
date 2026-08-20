defmodule Batata.Frontend.SigilMacroExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend

  @provider """
  defmodule JsonSigils do
    defmacro sigil_j(term, modifiers)

    defmacro sigil_j({:<<>>, _meta, [string]}, modifiers) when is_binary(string) do
      Macro.escape(Json.decode!(string, mods_to_opts(modifiers)))
    end

    defmacro sigil_j(term, modifiers) do
      quote(do: Json.decode!(unquote(term), unquote(mods_to_opts(modifiers))))
    end

    defmacro sigil_J(term, modifiers)

    defmacro sigil_J({:<<>>, _meta, [string]}, modifiers) when is_binary(string) do
      Macro.escape(Json.decode!(string, mods_to_opts(modifiers)))
    end

    defp mods_to_opts(modifiers), do: modifiers
  end
  """

  test "expands literal, interpolated, and raw sigils to explicit decoder calls" do
    consumer = ~S'''
    defmodule SigilConsumer do
      import JsonSigils
      def literal(), do: ~j'{"name":"batata"}'a
      def interpolated(value), do: ~j'{"value":"#{value}"}'r
      def raw(), do: ~J'"#{raw}"'c
    end
    '''

    modules = Frontend.from_sources([@provider, consumer])
    provider = Enum.find(modules, &(&1.name == JsonSigils))
    consumer = Enum.find(modules, &(&1.name == SigilConsumer))

    assert provider.unsupported == []
    assert consumer.unsupported == []

    bodies = Map.new(consumer.definitions, &{&1.name, hd(&1.clauses).body_ast})
    assert Macro.to_string(bodies.literal) =~ "Json.decode!"
    assert Macro.to_string(bodies.literal) =~ "keys: :atoms"
    assert Macro.to_string(bodies.interpolated) =~ "strings: :reference"
    assert Macro.to_string(bodies.raw) =~ "strings: :copy"
  end

  test "marks unknown modifiers without executing the provider" do
    consumer = """
    defmodule InvalidSigilConsumer do
      import JsonSigils
      def value(), do: sigil_j("{}", [?x])
    end
    """

    snapshot =
      Frontend.from_sources([@provider, consumer])
      |> Enum.find(&(&1.name == InvalidSigilConsumer))

    body = snapshot.definitions |> hd() |> Map.fetch!(:clauses) |> hd() |> Map.fetch!(:body_ast)
    assert Macro.to_string(body) =~ "__batata_unsupported_sigil__"
  end

  test "leaves unrelated sigil macros unsupported" do
    snapshot =
      Frontend.from_source("""
      defmodule ArbitrarySigil do
        defmacro sigil_j(term, _modifiers), do: term
      end
      """)

    assert [%Frontend.UnsupportedForm{reason: :unknown_form}] = snapshot.unsupported
  end
end
