defmodule Batata.Frontend.GuardSupportTest do
  use ExUnit.Case, async: true

  alias Batata.Frontend.GuardSupport

  test "classifies the guard shapes shared by inventory and lifting" do
    assert GuardSupport.supported?(quote(do: is_binary(value)))
    assert GuardSupport.supported?(quote(do: byte in ?0..?9))
    assert GuardSupport.supported?(quote(do: byte in [?e, ?E]))
    assert GuardSupport.supported?(quote(do: coefficient in [:NaN, :inf]))
    assert GuardSupport.supported?(quote(do: sign in [1, -1]))
    assert GuardSupport.supported?(quote(do: is_integer(value) and value != 0))
    assert GuardSupport.supported?(quote(do: value <= 0))
    assert GuardSupport.supported?(quote(do: value >= 0))
    assert GuardSupport.supported?(quote(do: value > other * 10))
    assert GuardSupport.supported?(quote(do: value - offset < other + 1))
    assert GuardSupport.supported?(quote(do: is_integer(value) and rem(value, 10) == 0))
    assert GuardSupport.supported?(quote(do: is_integer(value) and Kernel.rem(value, 10) == 0))
    assert GuardSupport.supported?(quote(do: list == []))
    assert GuardSupport.supported?(quote(do: pretty !== false))

    refute GuardSupport.supported?(quote(do: is_function(value, 1)))
    refute GuardSupport.supported?(quote(do: value >= rem(other, 10)))
    refute GuardSupport.supported?(quote(do: rem(value, 10) == 0))
    refute GuardSupport.supported?(quote(do: is_integer(value) or rem(value, 10) == 0))
    refute GuardSupport.supported?(quote(do: value <= byte_size(data)))
    refute GuardSupport.supported?(quote(do: value in [1, :inf]))
  end
end
