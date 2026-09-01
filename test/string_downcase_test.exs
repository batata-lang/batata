defmodule Batata.StringDowncaseTest do
  use Batata.Case, async: true, group: :execution_engine

  alias Batata
  alias Batata.Stdlib
  alias Beaver.MLIR

  @source """
  defmodule AsciiDowncase do
    def lower(value), do: String.downcase(value)

    def main() do
      {
        lower(""),
        lower("already lower"),
        lower("MiXeD ASCII 123!?"),
        lower("NFINITY"),
        lower("NF"),
        lower("AN"),
        lower(<<0, ?A, 127>>)
      }
    end
  end
  """

  test "declares the bounded operation and its execution metadata" do
    assert Stdlib.class({String, :downcase, 1}) == :native_term
    assert Stdlib.may_raise?({String, :downcase, 1})

    assert Stdlib.metadata({String, :downcase, 1}) == %{
             purity: :pure,
             allocation: :may_allocate,
             preemption: :none,
             reductions: :per_element
           }
  end

  test "downcases ASCII binaries against the BEAM oracle", %{ctx: ctx} do
    expected = @source |> Kernel.<>("\nAsciiDowncase.main()") |> Code.eval_string() |> elem(0)

    assert expected ==
             {"", "already lower", "mixed ascii 123!?", "nfinity", "nf", "an", <<0, ?a, 127>>}

    assert Batata.execute(@source, ctx) == expected
  end

  test "emits a verified traversal and binary reconstruction", %{ctx: ctx} do
    module = Batata.compile(@source, ctx)

    assert MLIR.verify?(module)

    rendered = MLIR.to_string(module, generic: true)
    assert rendered =~ "scf.while"
    assert rendered =~ "ex.binary_get"
    assert rendered =~ "ex.list_cons"
    assert rendered =~ "ex.binary_from_list"
  end

  test "raises instead of approximating non-binary or Unicode inputs", %{ctx: ctx} do
    for value <- [:not_binary, "Ä", "Σ", "İ"] do
      source = """
      defmodule InvalidAsciiDowncase do
        def main(), do: String.downcase(#{inspect(value)})
      end
      """

      assert_raise ArgumentError, "String.downcase/1 supports ASCII binaries only", fn ->
        Batata.execute(source, ctx)
      end
    end
  end
end
