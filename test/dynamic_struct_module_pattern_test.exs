defmodule Batata.DynamicStructModulePatternTest do
  use Batata.Case, async: true, group: :execution_engine

  @source """
  defmodule DynamicStructModulePatternFixture do
    defstruct kind: :named, meta: %{}

    def first(%module{} = whole), do: {:struct, module, whole}
    def first(_other), do: :other

    def trailing(:encode, %module{meta: %{kind: kind}} = whole),
      do: {:encode, module, kind, whole}

    def trailing(_tag, _other), do: :other

    def jason_shape(%module{} = value, {escape, encode_map}),
      do: {module, value, escape, encode_map}

    def jason_shape(_value, _opts), do: :other

    def main() do
      named = %__MODULE__{kind: :named, meta: %{kind: :nested}}
      nil_struct = %{__struct__: nil, kind: :nil_atom, meta: %{kind: :nil_nested}}
      invalid_struct = %{__struct__: 123, kind: :integer, meta: %{kind: :invalid}}
      ordinary = %{kind: :map, meta: %{kind: :ordinary}}

      {
        first(named),
        first(nil_struct),
        first(invalid_struct),
        first(ordinary),
        first(42),
        trailing(:encode, named),
        trailing(:encode, nil_struct),
        trailing(:encode, invalid_struct),
        trailing(:other, named),
        jason_shape(named, {:json, :naive})
      }
    end
  end
  """

  test "binds generic struct modules with BEAM dispatch semantics", %{ctx: ctx} do
    expected =
      @source
      |> Kernel.<>("\nDynamicStructModulePatternFixture.main()")
      |> Code.eval_string()
      |> elem(0)

    assert Batata.execute(@source, ctx) == expected
  end

  test "routes dynamic struct modules through the generic struct matcher", %{ctx: ctx} do
    ir = @source |> Batata.compile(ctx) |> Beaver.MLIR.to_string(generic: true)
    assert ir =~ ~s{"ex.map_fetch"}
    assert ir =~ ~s{"ex.is_map"}
    assert ir =~ ~s{"ex.is_atom"}
  end

  test "rejects repeated dynamic module bindings until equality is modeled", %{ctx: ctx} do
    source = """
    defmodule RepeatedDynamicStructModule do
      def route(%module{kind: module}), do: module
      def route(_other), do: :other
      def main(), do: route(%{__struct__: Date, kind: Date})
    end
    """

    assert_raise Batata.Lift.Error,
                 ~r/dynamic struct module repeats binding: :module/,
                 fn -> Batata.compile(source, ctx) end
  end
end
