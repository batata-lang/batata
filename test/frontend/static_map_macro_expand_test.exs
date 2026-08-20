defmodule Batata.Frontend.StaticMapMacroExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend

  @provider """
  defmodule MapBuilder do
    defmacro fragment(kv) do
      vars = Enum.map(kv, &elem(&1, 0))
      iodata = Builder.build_kv_iodata(vars, [])

      quote do
        %Fragment{encode: fn _opts -> unquote(iodata) end}
      end
    end

    defmacro fragment_take(map, keys) do
      iodata = Builder.build_kv_iodata(keys, [])

      quote do
        case unquote(map) do
          values -> %Fragment{encode: fn _opts -> {values, unquote(iodata)} end}
        end
      end
    end
  end
  """

  test "expands literal-key map macros without loading their provider" do
    consumer = """
    defmodule MapConsumer do
      import MapBuilder, only: [fragment: 1, fragment_take: 2]

      def literal(left, right), do: fragment(alpha: left, beta: right)
      def take(map), do: fragment_take(map, [:beta, :alpha])
    end
    """

    modules = Frontend.from_sources([@provider, consumer])
    provider = Enum.find(modules, &(&1.name == MapBuilder))
    consumer = Enum.find(modules, &(&1.name == MapConsumer))

    assert provider.unsupported == []
    assert consumer.unsupported == []

    assert Macro.to_string(
             Enum.find(consumer.definitions, &(&1.name == :literal)).clauses
             |> hd()
             |> Map.fetch!(:body_ast)
           ) =~
             "Encode.value"

    assert Macro.to_string(
             Enum.find(consumer.definitions, &(&1.name == :take)).clauses
             |> hd()
             |> Map.fetch!(:body_ast)
           ) =~
             "%{beta:"
  end

  test "keeps non-literal keys fail closed" do
    consumer = """
    defmodule DynamicMapConsumer do
      import MapBuilder, only: [fragment_take: 2]
      def take(map, keys), do: fragment_take(map, keys)
    end
    """

    snapshot =
      Frontend.from_sources([@provider, consumer]) |> Enum.find(&(&1.name == DynamicMapConsumer))

    definition = Enum.find(snapshot.definitions, &(&1.name == :take))

    assert Macro.to_string(hd(definition.clauses).body_ast) =~
             "__batata_unsupported_static_map_macro__"
  end

  test "does not infer support from a helper call alone" do
    provider = """
    defmodule ArbitraryBuilder do
      defmacro fragment(value) do
        Builder.build_kv_iodata([], [])
        quote(do: unquote(value) + 1)
      end
    end
    """

    snapshot = Frontend.from_source(provider)
    assert [%Frontend.UnsupportedForm{reason: :unknown_form}] = snapshot.unsupported
  end

  test "accepts a bounded deriving provider that emits a defimpl" do
    source = """
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

      def encode(value, opts), do: {value, opts}
    end
    """

    snapshot = Frontend.from_sources([source]) |> List.first()

    assert snapshot.name == Sample.Encoder.Any
    assert snapshot.unsupported == []
    assert Enum.map(snapshot.definitions, & &1.name) == [:encode]
  end
end
