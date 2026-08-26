defmodule Batata.FrontendTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend

  @source """
  defmodule Math do
    @moduledoc false

    def main() do
      a = 1 + 2
      a + 3
    end
  end
  """

  test "normalizes an expanded module snapshot" do
    snapshot = Frontend.from_source(@source)

    assert snapshot.name == Math

    assert [
             %Frontend.Definition{
               kind: :def,
               name: :main,
               arity: 0,
               clauses: [%Frontend.Clause{patterns: []}]
             }
           ] = snapshot.definitions

    assert snapshot.unsupported == []
  end

  test "records module-body forms outside the boundary" do
    snapshot =
      Frontend.from_source("""
      defmodule M do
        require Logger

        def main() do
          :ok
        end
      end
      """)

    assert Enum.map(snapshot.unsupported, & &1.reason) == [:require]
  end

  test "preserves guards on expanded function definitions" do
    snapshot =
      Frontend.from_source("""
      defmodule Scanner do
        def digit(<<byte, rest::binary>>) when byte in ?0..?9, do: rest
      end
      """)

    assert [
             %Frontend.Definition{
               name: :digit,
               clauses: [%Frontend.Clause{guard_ast: {:in, _, _}}]
             }
           ] = snapshot.definitions
  end

  test "normalizes imported and explicit Kernel.raise/1 calls" do
    snapshot =
      Frontend.from_source("""
      defmodule Raising do
        def imported(error), do: raise error
        def explicit(error), do: Kernel.raise(error)
      end
      """)

    assert [
             {:__batata_raise__, _, [9, {:error, _, nil}]},
             {:__batata_raise__, _, [9, {:error, _, nil}]}
           ] =
             Enum.map(snapshot.definitions, fn definition ->
               definition.clauses |> hd() |> Map.fetch!(:body_ast)
             end)
  end

  test "preserves a genuine local raise/1 definition and its calls" do
    snapshot =
      Frontend.from_source("""
      defmodule LocalRaise do
        def raise(value), do: {:local, value}
        def call(value), do: raise(value)
        def kernel(value), do: Kernel.raise(value)
      end
      """)

    [local, call, kernel] = snapshot.definitions

    assert {:local, {:value, _, nil}} = local.clauses |> hd() |> Map.fetch!(:body_ast)

    assert {:raise, _, [{:value, _, nil}]} =
             call.clauses |> hd() |> Map.fetch!(:body_ast)

    assert {:__batata_raise__, _, [9, {:value, _, nil}]} =
             kernel.clauses |> hd() |> Map.fetch!(:body_ast)
  end

  test "normalizes default arguments into callable arities" do
    snapshot =
      Frontend.from_source("""
      defmodule Options do
        def get(input, opts \\\\ []), do: {input, opts}
      end
      """)

    assert Enum.map(snapshot.definitions, &{&1.name, &1.arity}) == [get: 1, get: 2]
    assert snapshot.unsupported == []
  end

  test "normalizes struct and exception schemas with literal defaults" do
    struct =
      Frontend.from_source("""
      defmodule DecimalLike do
        defstruct sign: 1, coef: 0, tags: []
      end
      """)

    assert %Frontend.StructSchema{
             module: DecimalLike,
             kind: :struct,
             fields: [sign: 1, coef: 0, tags: []]
           } = struct.struct_schema

    exception =
      Frontend.from_source("""
      defmodule ErrorLike do
        defexception [:message]
      end
      """)

    assert %Frontend.StructSchema{
             module: ErrorLike,
             kind: :exception,
             fields: [message: nil]
           } = exception.struct_schema
  end

  test "fails closed on invalid or duplicate struct schemas" do
    invalid_sources = [
      "defmodule Invalid do defstruct [:value, :value] end",
      "defmodule Invalid do defstruct [__struct__: nil] end",
      "defmodule Invalid do defstruct [value: helper()] end",
      "defmodule Invalid do defstruct [:value]; defexception [:message] end"
    ]

    for source <- invalid_sources do
      snapshot = Frontend.from_source(source)
      assert snapshot.struct_schema == nil
      assert snapshot.unsupported != []
    end
  end
end
