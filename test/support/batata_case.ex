defmodule Batata.Case do
  @moduledoc """
  Test case for batata tests, with an MLIR context created and destroyed
  automatically.
  """

  use ExUnit.CaseTemplate

  using options do
    quote do
      alias Beaver.MLIR

      setup do
        ctx = MLIR.Context.create(unquote(options))

        on_exit(fn ->
          MLIR.Context.destroy(ctx)
        end)

        %{ctx: ctx}
      end
    end
  end
end
