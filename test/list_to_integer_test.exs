defmodule Batata.ListToIntegerTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Batata.Stdlib
  alias Beaver.MLIR

  @source """
  defmodule CharlistToInteger do
    def decimal(value), do: List.to_integer(value)
    def erlang(value), do: :erlang.list_to_integer(value)

    def main() do
      {
        decimal(~c"0"),
        decimal(~c"00"),
        decimal(~c"+0012"),
        decimal(~c"-0"),
        decimal(~c"-0012"),
        decimal(~c"1234567890123456789012345678901234567890"),
        erlang(~c"42"),
        erlang(~c"-1152921504606846977"),
        decimal(~c"1234")
      }
    end
  end
  """

  test "declares both aliases and their execution metadata" do
    for mfa <- [{List, :to_integer, 1}, {:erlang, :list_to_integer, 1}] do
      assert Stdlib.class(mfa) == :native_term
      assert Stdlib.may_raise?(mfa)

      assert Stdlib.metadata(mfa) == %{
               purity: :pure,
               allocation: :may_allocate,
               preemption: :none,
               reductions: :per_element
             }
    end
  end

  test "parses signed, normalized, and arbitrary-precision integers against BEAM", %{ctx: ctx} do
    expected = @source |> Kernel.<>("\nCharlistToInteger.main()") |> Code.eval_string() |> elem(0)

    assert expected ==
             {0, 0, 12, 0, -12, 1_234_567_890_123_456_789_012_345_678_901_234_567_890, 42,
              -1_152_921_504_606_846_977, 1234}

    assert Batata.execute(@source, ctx) == expected
  end

  test "emits verified validation, normalization, and bigint construction", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    assert MLIR.verify?(module)

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "scf.while"
    assert rendered =~ "ex.iodata_to_binary"
    assert rendered =~ "ex.list_get"
    assert rendered =~ "ex.binary_slice"
    assert rendered =~ "ex.bigint_lit"
  end

  test "rejects malformed or non-flat character lists", %{ctx: ctx} do
    for value <- [[], ~c"+", ~c"-", ~c"12x", :not_a_list, [49 | 50], [[49], 50], [49, :bad]] do
      source = """
      defmodule InvalidCharlistToInteger do
        def main(), do: List.to_integer(#{inspect(value)})
      end
      """

      assert_raise ArgumentError, "invalid List.to_integer/1 argument", fn ->
        Batata.execute(source, ctx)
      end
    end
  end

  test "uses the Erlang alias in fail-closed errors", %{ctx: ctx} do
    source = """
    defmodule InvalidErlangCharlistToInteger do
      def main(), do: :erlang.list_to_integer(~c"1x")
    end
    """

    assert_raise ArgumentError, "invalid :erlang.list_to_integer/1 argument", fn ->
      Batata.execute(source, ctx)
    end
  end
end
