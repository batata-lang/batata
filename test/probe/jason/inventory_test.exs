defmodule Batata.Probe.Jason.InventoryTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.Inventory

  @tag :tmp_dir
  test "discovers every unsupported form instead of stopping at the first", %{tmp_dir: tmp_dir} do
    source = """
    defmodule Outer do
      @moduledoc false
      @compile {:inline, plain: 1}
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

    assert outer.definitions == [
             %{kind: :def, name: :guarded, arity: 1, clauses: 1},
             %{kind: :def, name: :at_end, arity: 2, clauses: 1},
             %{kind: :def, name: :plain, arity: 1, clauses: 1}
           ]

    assert Enum.map(outer.unsupported, & &1.reason) == [
             :ignored_metadata,
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
    assert Enum.at(outer.unsupported, 1).attribute == :compile
    assert Enum.at(outer.unsupported, 2).attribute == :semantic_key
    assert Enum.at(outer.unsupported, 3).attribute == :digits

    assert Enum.map(inner.unsupported, & &1.reason) == [:require]
  end

  @tag :tmp_dir
  test "records parse errors without crashing the whole inventory", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "broken.ex"), "defmodule Broken do")

    assert [%{status: :parse_error, parse_error: parse_error}] = Inventory.discover!(tmp_dir)
    assert is_binary(parse_error.description)
  end
end
