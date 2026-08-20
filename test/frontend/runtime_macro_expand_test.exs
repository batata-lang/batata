defmodule Batata.Frontend.RuntimeMacroExpandTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend

  test "normalizes a bind_quoted private macro into an equivalent private function" do
    snapshot =
      Frontend.from_source("""
      defmodule Sample do
        defmacrop checked(value, fallback \\\\ nil) do
          quote bind_quoted: binding() do
            if value >= 0, do: value, else: fallback
          end
        end

        def value(), do: checked(3)
      end
      """)

    assert snapshot.unsupported == []

    assert Enum.map(snapshot.definitions, &{&1.kind, &1.name, &1.arity}) == [
             {:defp, :checked, 1},
             {:defp, :checked, 2},
             {:def, :value, 0}
           ]
  end

  test "substitutes caller-context templates in normal bodies and guards" do
    snapshot =
      Frontend.from_source("""
      defmodule Sample do
        defmacro structured(value)

        defmacro structured(value) do
          case __CALLER__.context do
            nil ->
              quote do
                case unquote(value) do
                  %{} -> true
                  _ -> false
                end
              end

            :match ->
              raise ArgumentError, "not valid in a match"

            :guard ->
              quote do
                is_map(unquote(value))
              end
          end
        end

        def normal(value), do: structured(value)
        def guarded(value) when structured(value), do: value
      end
      """)

    assert snapshot.unsupported == []
    assert Enum.map(snapshot.definitions, & &1.name) == [:normal, :guarded]

    normal = Enum.find(snapshot.definitions, &(&1.name == :normal))
    guarded = Enum.find(snapshot.definitions, &(&1.name == :guarded))

    assert Macro.to_string(hd(normal.clauses).body_ast) =~ "case value do"
    assert Macro.to_string(hd(guarded.clauses).guard_ast) == "is_map(value)"
  end

  test "leaves arbitrary quoted macros unsupported" do
    snapshot =
      Frontend.from_source("""
      defmodule Sample do
        defmacro increment(value) do
          quote do
            unquote(value) + 1
          end
        end
      end
      """)

    assert [%Frontend.UnsupportedForm{reason: :unknown_form}] = snapshot.unsupported
  end
end
