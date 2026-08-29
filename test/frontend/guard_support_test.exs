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
    refute GuardSupport.supported?(quote(do: is_function(value)))
    refute GuardSupport.supported?(quote(do: is_function(value, 1)))
    assert GuardSupport.compiler_supported?(quote(do: is_function(value)))
    assert GuardSupport.compiler_supported?(quote(do: is_function(value, 1)))

    refute GuardSupport.compiler_supported?(quote(do: is_function(value, 5)))
    refute GuardSupport.compiler_supported?(quote(do: is_function(value, arity)))
    refute GuardSupport.supported?(quote(do: value >= rem(other, 10)))
    refute GuardSupport.supported?(quote(do: rem(value, 10) == 0))
    refute GuardSupport.supported?(quote(do: is_integer(value) or rem(value, 10) == 0))
    refute GuardSupport.supported?(quote(do: value <= byte_size(data)))
    refute GuardSupport.supported?(quote(do: value in [1, :inf]))
  end

  test "classifies canonical escaped unit ranges without admitting stepped or malformed ranges" do
    byte = {:byte, [], nil}

    for range <- [0..31, 31..0//-1] do
      guard = {:in, [], [byte, Macro.escape(range)]}
      assert GuardSupport.supported?(guard)
      assert GuardSupport.compiler_supported?(guard)
    end

    refute GuardSupport.compiler_supported?({:in, [], [byte, Macro.escape(0..10//2)]})

    refute GuardSupport.compiler_supported?(
             {:in, [],
              [
                byte,
                {:%{}, [], [__struct__: Range, first: 0, last: 31, step: 1, extra: true]}
              ]}
           )

    refute GuardSupport.compiler_supported?(
             {:in, [],
              [byte, {:%{}, [], [__struct__: Range, first: 0, last: :thirty_one, step: 1]}]}
           )
  end

  test "expands escapes in literal charlist members" do
    members = quote(do: ~c'\s\n\t\r')

    assert GuardSupport.term_members(members) == {:integer_set, [32, 10, 9, 13]}
    refute ?n in elem(GuardSupport.term_members(members), 1)
  end
end
