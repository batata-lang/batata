defmodule Batata.Probe.CorpusRuntimeSliceTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend
  alias Batata.Probe.CorpusRuntimeSlice

  @tag :tmp_dir
  test "removes compile-time providers and helpers while preserving runtime roots", %{
    tmp_dir: tmp_dir
  } do
    provider = """
    defmodule Fixture.Provider do
      defstruct [:value]
      def build(value), do: helper(value)
      def shared(value), do: value
      def unknown(value), do: value
      defp helper(value), do: value
    end
    """

    consumer = """
    defmodule Fixture.Consumer do
      defmacro generated(value), do: Fixture.Provider.build(value)
      def runtime(value), do: Fixture.Provider.shared(value)
    end
    """

    File.write!(Path.join(tmp_dir, "provider.ex"), provider)
    File.write!(Path.join(tmp_dir, "consumer.ex"), consumer)

    result = CorpusRuntimeSlice.slice(tmp_dir, Frontend.from_sources([provider, consumer]))
    sliced = Enum.find(result.modules, &(&1.name == Fixture.Provider))
    signatures = MapSet.new(sliced.definitions, &{&1.name, &1.arity})

    refute MapSet.member?(signatures, {:build, 1})
    refute MapSet.member?(signatures, {:helper, 1})
    assert MapSet.member?(signatures, {:shared, 1})
    assert MapSet.member?(signatures, {:unknown, 1})
    assert sliced.struct_schema.module == Fixture.Provider

    assert result.removed_definitions == [
             %{"module" => "Fixture.Provider", "function" => "build", "arity" => 1},
             %{"module" => "Fixture.Provider", "function" => "helper", "arity" => 1}
           ]
  end

  @tag :tmp_dir
  test "keeps a provider that also has a runtime incoming edge", %{tmp_dir: tmp_dir} do
    provider = """
    defmodule Fixture.Provider do
      def build(value), do: helper(value)
      defp helper(value), do: value
    end
    """

    consumer = """
    defmodule Fixture.Consumer do
      defmacro generated(value), do: Fixture.Provider.build(value)
      def runtime(value), do: Fixture.Provider.build(value)
    end
    """

    File.write!(Path.join(tmp_dir, "provider.ex"), provider)
    File.write!(Path.join(tmp_dir, "consumer.ex"), consumer)

    result = CorpusRuntimeSlice.slice(tmp_dir, Frontend.from_sources([provider, consumer]))
    sliced = Enum.find(result.modules, &(&1.name == Fixture.Provider))
    signatures = MapSet.new(sliced.definitions, &{&1.name, &1.arity})

    assert MapSet.member?(signatures, {:build, 1})
    assert MapSet.member?(signatures, {:helper, 1})
    assert result.removed_definitions == []
  end
end
