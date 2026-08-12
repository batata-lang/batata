defmodule Batata.Probe.Jason.InventoryTest do
  use ExUnit.Case, async: true

  alias Batata.Probe.Jason.Inventory

  @tag :tmp_dir
  test "discovers every unsupported form instead of stopping at the first", %{tmp_dir: tmp_dir} do
    source = """
    defmodule Outer do
      @moduledoc false
      import Bitwise
      def guarded(value) when is_integer(value), do: value
      def unsupported(value) when value > 0, do: value
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
             %{kind: :def, name: :plain, arity: 1, clauses: 1}
           ]

    assert Enum.map(outer.unsupported, & &1.reason) == [
             :module_attribute,
             :import,
             :guarded_definition,
             :nested_defmodule
           ]

    assert Enum.map(inner.unsupported, & &1.reason) == [:require]
  end

  @tag :tmp_dir
  test "records parse errors without crashing the whole inventory", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "broken.ex"), "defmodule Broken do")

    assert [%{status: :parse_error, parse_error: parse_error}] = Inventory.discover!(tmp_dir)
    assert is_binary(parse_error.description)
  end
end
