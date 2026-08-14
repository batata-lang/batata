defmodule Batata.Probe.Jason.InventoryTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.Inventory

  @tag :tmp_dir
  test "discovers every unsupported form instead of stopping at the first", %{tmp_dir: tmp_dir} do
    source = """
    defmodule Outer do
      @moduledoc false
      @behaviour Access
      @compile {:inline, plain: 1}
      @dialyzer :no_improper_lists
      @impl Access
      @compile {:always, plain: 1}
      @dialyzer {:nowarn_function, plain: 1}
      @impl false
      @semantic_key :value
      @digits Enum.to_list(0..9)
      import Bitwise
      defstruct [:value]
      defexception [:message]
      defrecordp :state, value: nil
      defmacro generated(value), do: value
      generated :value
      for value <- [1], do: defp(generated_value(), do: value)
      def guarded(value) when is_integer(value), do: value
      def at_end(position, data) when position == byte_size(data), do: position
      def unsupported(value) when is_function(value, 1), do: value
      def plain(value), do: value

      defmodule Inner do
        require Logger
        def child(), do: 1
      end
    end
    """

    path = Path.join(tmp_dir, "sample.ex")
    File.write!(path, source)

    assert [file] = Inventory.discover!(tmp_dir)
    assert file.status == :parsed
    assert Enum.map(file.modules, & &1.module) == ["Outer", "Outer.Inner"]

    [outer, inner] = file.modules
    assert outer.compile_source == nil
    assert inner.compile_source == nil

    assert outer.definitions == [
             %{kind: :def, name: :guarded, arity: 1, clauses: 1},
             %{kind: :def, name: :at_end, arity: 2, clauses: 1},
             %{kind: :def, name: :plain, arity: 1, clauses: 1}
           ]

    assert Enum.map(outer.unsupported, & &1.reason) == [
             :ignored_metadata,
             :ignored_metadata,
             :ignored_metadata,
             :ignored_metadata,
             :ignored_metadata,
             :compile_annotation,
             :compile_annotation,
             :compile_annotation,
             :semantic_module_attribute,
             :compile_time_eval_attribute,
             :import,
             :struct_semantics,
             :exception_semantics,
             :record_semantics,
             :macro_definition,
             :module_level_generation,
             :module_level_generation,
             :guarded_definition,
             :nested_defmodule
           ]

    assert hd(outer.unsupported).attribute == :moduledoc

    assert Enum.map(Enum.take(outer.unsupported, 8), & &1.attribute) == [
             :moduledoc,
             :behaviour,
             :compile,
             :dialyzer,
             :impl,
             :compile,
             :dialyzer,
             :impl
           ]

    assert Enum.at(outer.unsupported, 8).attribute == :semantic_key
    assert Enum.at(outer.unsupported, 9).attribute == :digits

    assert Enum.map(inner.unsupported, & &1.reason) == [:require]
  end

  @tag :tmp_dir
  test "builds a self-contained compile candidate only for eligible modules", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "eligible.ex"), """
    defmodule Eligible do
      @moduledoc false
      def double(value), do: value * 2
    end
    """)

    assert [%{modules: [module]}] = Inventory.discover!(tmp_dir)
    assert module.unsupported |> Enum.map(& &1.reason) == [:ignored_metadata]
    assert module.compile_source =~ "defmodule Eligible"
    assert module.compile_source =~ "def main do"
    refute module.compile_source =~ "@moduledoc"
  end

  @tag :tmp_dir
  test "records parse errors without crashing the whole inventory", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "broken.ex"), "defmodule Broken do")

    assert [%{status: :parse_error, parse_error: parse_error}] = Inventory.discover!(tmp_dir)
    assert is_binary(parse_error.description)
  end

  @tag :tmp_dir
  test "uses frontend alias expansion for inventory and compile source", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "sample.ex"), """
    defmodule Sample do
      alias Jason.Decoder
      def parse(input), do: Decoder.parse(input)
    end
    """)

    assert [%{modules: [module]}] = Inventory.discover!(tmp_dir)
    assert module.unsupported == []
    assert module.compile_source =~ "Jason.Decoder.parse(input)"
    refute module.compile_source =~ "alias "
  end

  @tag :tmp_dir
  test "keeps source definition counts while compiling expanded default arities", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, "sample.ex"), """
    defmodule Sample do
      def parse(input, opts \\\\ []), do: {input, opts}
    end
    """)

    assert [%{modules: [module]}] = Inventory.discover!(tmp_dir)
    assert module.definitions == [%{kind: :def, name: :parse, arity: 2, clauses: 1}]
    assert module.unsupported == []
    assert module.compile_source =~ "def parse(batata_arg0)"
    assert module.compile_source =~ "def parse(input, opts)"
    refute module.compile_source =~ "\\\\"
  end

  @tag :tmp_dir
  test "known compile metadata shapes preserve BEAM results", %{tmp_dir: tmp_dir} do
    original = Path.join(tmp_dir, "original.exs")
    stripped = Path.join(tmp_dir, "stripped.exs")

    File.write!(original, """
    defmodule MetadataBehaviour do
      @callback value() :: integer()
    end

    defmodule MetadataFixture do
      @behaviour MetadataBehaviour
      @compile {:inline, value: 0}
      @dialyzer :no_improper_lists
      @impl true
      def value, do: 42
    end
    IO.write(MetadataFixture.value())
    """)

    File.write!(stripped, """
    defmodule MetadataBehaviour do
      @callback value() :: integer()
    end

    defmodule MetadataFixture do
      def value, do: 42
    end
    IO.write(MetadataFixture.value())
    """)

    assert {"42", 0} = System.cmd("elixir", [original], stderr_to_stdout: false)
    assert {"42", 0} = System.cmd("elixir", [stripped], stderr_to_stdout: false)
  end
end
