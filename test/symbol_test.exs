defmodule Batata.SymbolTest do
  use ExUnit.Case, async: true

  alias Batata.Symbol

  test "encodes function identity without source-name collisions" do
    assert Symbol.function(:abc, 3) == "__batata_fn_616263_3"
    assert Symbol.function(:abc, 3) != Symbol.function(:abc, 4)
    assert Symbol.function(:abc, 3) != Symbol.function(:__batata_fn_616263_3, 0)

    assert Symbol.function(:"+/雪", 2) =~ ~r/^__batata_fn_[0-9a-f]+_2$/
  end

  test "preserves runtime-reserved function symbols" do
    assert Symbol.function(:__batata_entry, 0) == "__batata_entry"
    assert Symbol.function(:__fn_dispatch, 9) == "__fn_dispatch"
  end
end
