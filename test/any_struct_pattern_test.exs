defmodule Batata.AnyStructPatternTest do
  use Batata.Case, async: true

  test "matches generic struct patterns with BEAM semantics", %{ctx: ctx} do
    source = """
    defmodule AnyStructPatternOracle do
      defstruct kind: :named, meta: %{}

      def first(%_{} = whole), do: {:struct, whole}
      def first(_other), do: :other

      def fields(%_{kind: kind} = whole), do: {:fields, kind, whole}
      def fields(_other), do: :other

      def trailing(:tag, %_{meta: %{kind: kind}} = whole), do: {:trailing, kind, whole}
      def trailing(_tag, _other), do: :other

      def case_value(value) do
        case value do
          %_{} = whole -> {:case, whole}
          _other -> :other
        end
      end

      def main() do
        named = %__MODULE__{kind: :named, meta: %{kind: :nested}}
        nil_struct = %{__struct__: nil, kind: :nil_atom, meta: %{kind: :nil_nested}}
        invalid_struct = %{__struct__: 123, kind: :integer}
        ordinary = %{kind: :map}

        {
          first(named),
          first(nil_struct),
          first(invalid_struct),
          first(ordinary),
          first(42),
          fields(named),
          fields(nil_struct),
          trailing(:tag, named),
          trailing(:tag, nil_struct),
          trailing(:tag, invalid_struct),
          case_value(named),
          case_value(invalid_struct)
        }
      end
    end
    """

    expected =
      source |> Kernel.<>("\nAnyStructPatternOracle.main()") |> Code.eval_string() |> elem(0)

    assert Batata.execute(source, ctx) == expected
  end
end
