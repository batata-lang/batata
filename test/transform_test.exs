defmodule Batata.TransformTest do
  use Batata.Case, async: true

  alias Batata.{Frontend, Lift, Transform}
  alias Batata.Transform.InlineScalarCalls
  alias Beaver.MLIR

  defp transform!(source, ctx) do
    source
    |> Frontend.from_source()
    |> Lift.module_to_ir(ctx: ctx)
    |> Beaver.Deferred.resolve(ctx)
    |> Transform.run!([InlineScalarCalls])
    |> MLIR.verify!()
  end

  test "inlines scalar calls so results participate in arithmetic", %{ctx: ctx} do
    module =
      transform!(
        """
        defmodule Math do
          def add(a, b) do
            a + b
          end

          def main() do
            add(1, 2) + 3
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    refute rendered =~ ~s{callee = "add"}
    assert rendered =~ ~s{"ex.add"}
  end

  test "inlines nested scalar calls innermost-first", %{ctx: ctx} do
    module =
      transform!(
        """
        defmodule Math do
          def add(a, b) do
            a + b
          end

          def main() do
            add(add(1, 2), add(3, 4))
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    refute rendered =~ ~s{callee = "add"}
    assert rendered =~ ~s{"ex.add"}
  end

  test "leaves non-scalar callees as ex.call", %{ctx: ctx} do
    module =
      transform!(
        """
        defmodule Math do
          def pair() do
            {1, 2}
          end

          def main() do
            is_tuple(pair())
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ ~s{"ex.call"}
  end

  test "leaves unknown callees as ex.call", %{ctx: ctx} do
    module =
      transform!(
        """
        defmodule Math do
          def main() do
            missing(1, 2)
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ ~s{"ex.call"}
  end

  test "retypes recursive scalar-returning calls so arithmetic verifies", %{ctx: ctx} do
    module =
      transform!(
        """
        defmodule Math do
          def count(<<>>) do
            0
          end

          def count(<<_h::8, t::binary>>) do
            1 + count(t)
          end

          def count(_) do
            0
          end

          def main() do
            count(<<1, 2>>)
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    # the recursive call is retyped to i64 and stays a call (not inlined)
    assert rendered =~ ~s{"ex.call"}
  end

  test "decodes term integers before passing them to scalar callees", %{ctx: ctx} do
    source = """
    defmodule TupleScalarBoundary do
      def add(left, right) when is_integer(left) and is_integer(right), do: left + right

      def main() do
        pair = {2, 3}
        add(elem(pair, 0), elem(pair, 1))
      end
    end
    """

    assert Batata.execute(source, ctx) == 5
  end

  test "preserves abstract !ex.term types across transform passes", %{ctx: ctx} do
    module =
      transform!(
        """
        defmodule TermTransform do
          def make_tuple(a, b), do: {a, b}

          def main() do
            t = make_tuple(1, 2)
            elem(t, 0)
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "!ex.term"
    assert rendered =~ "ex.tuple"
  end

  test "folds explicit unboxes when retyping term applies", %{ctx: ctx} do
    module =
      transform!(
        """
        defmodule Math do
          def apply_twice(f, g, value) do
            g.(f.(value))
          end

          def main() do
            apply_twice(fn x -> x + 1 end, fn x -> x * 2 end, 3)
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ ~r/"ex\.apply".*-> i64/s
    refute rendered =~ ~r/"ex\.unbox"\([^\n]*\) : \(i64\) -> i64/
  end

  test "expands integer cases over :binary.at without mixed comparison operands", %{ctx: ctx} do
    module =
      Batata.compile(
        """
        defmodule BinaryDispatch do
          def classify(binary, position) do
            case :binary.at(binary, position) do
              92 -> 1
              34 -> 2
              _ -> 0
            end
          end
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ ~s{"ex.binary_get"}
    assert rendered =~ ~r/"ex\.binary_get".*"ex\.to_int"/s
    refute rendered =~ ~r/"ex\.cmp"\([^\n]*!ex\.term/
  end
end
