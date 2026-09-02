defmodule Batata.TransformTest do
  use Batata.Case, async: true, group: :execution_engine

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

  test "bulk-inlines more than one legacy pass worth of independent calls", %{ctx: ctx} do
    calls = Enum.map_join(1..80, "\n", &"value#{&1} = add(#{&1}, #{&1})")

    module =
      transform!(
        """
        defmodule ManyScalarCalls do
          def add(left, right), do: left + right

          def main() do
            #{calls}
            value80
          end
        end
        """,
        ctx
      )

    refute MLIR.to_string(module, generic: true) =~ ~s{callee = "add"}
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

  test "retypes scalar control-flow calls without cloning nested regions", %{ctx: ctx} do
    module =
      transform!(
        """
        defmodule ScalarControlFlow do
          def choose(value) do
            case value do
              0 -> 1
              _ -> 2
            end
          end

          def main(), do: choose(0) + 3
        end
        """,
        ctx
      )

    rendered = MLIR.to_string(module, generic: true)

    assert rendered =~
             ~r/"ex\.call".*callee = "__batata_fn_63686f6f7365_1".*\(i64\) -> i64/
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

  test "folds term adapters made stale by scalar call retyping", %{ctx: ctx} do
    source = """
    defmodule RetypedScalarAdapters do
      defstruct coef: 0

      defp pow10(0), do: 1
      defp pow10(n), do: 10 * pow10(n - 1)

      defp pad_num(%__MODULE__{coef: coef}, n) do
        coef * pow10(Kernel.max(n, 0) + 1)
      end

      def main() do
        number = %__MODULE__{coef: 10}
        padded = pad_num(number, 1)
        if padded == 1_000, do: Kernel.div(padded, 10), else: 0
      end
    end
    """

    module = Batata.compile(source, ctx)
    rendered = MLIR.to_string(module, generic: true)

    refute rendered =~ ~r/"ex\.(?:is_integer|to_int)"\([^\n]*\) : \(i64\)/
    refute rendered =~ ~r/"ex\.term_eq"\([^\n]*\) : \(i64, i64\)/
  end

  test "reboxes integer ordering operands made scalar by call retyping", %{ctx: ctx} do
    source = """
    defmodule RetypedIntegerOrdering do
      defp pow10(0), do: 1
      defp pow10(n), do: 10 * pow10(n - 1)

      def main(), do: pow10(2) < pow10(3)
    end
    """

    module = Batata.compile(source, ctx)
    rendered = MLIR.to_string(module, generic: true)

    refute rendered =~ ~r/"ex\.integer_compare"\([^\n]*\) : \([^)]*i64/
    assert Batata.execute(source, ctx) == 1
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
