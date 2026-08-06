defmodule BatataTest do
  use ExUnit.Case, async: true

  alias Beaver.MLIR

  test "compiles source into verified ex IR" do
    ctx = MLIR.Context.create()

    try do
      module =
        Batata.compile(
          """
          defmodule Math do
            def main() do
              1 + 2
            end
          end
          """,
          ctx
        )

      assert MLIR.verify?(module)
      assert MLIR.to_string(module, generic: true) =~ ~s{"ex.func"}
      assert MLIR.to_string(module, generic: true) =~ ~s{"ex.add"}
    after
      MLIR.Context.destroy(ctx)
    end
  end
end
