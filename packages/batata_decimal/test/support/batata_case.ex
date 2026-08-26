defmodule Batata.Decimal.Case do
  @moduledoc false

  use ExUnit.CaseTemplate

  using options do
    quote do
      alias Beaver.MLIR

      setup do
        ctx = MLIR.Context.create(unquote(options))
        on_exit(fn -> MLIR.Context.destroy(ctx) end)
        %{ctx: ctx}
      end
    end
  end
end
