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

    assert [%Frontend.UnsupportedForm{reason: :module_attribute}] = snapshot.unsupported
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
end
