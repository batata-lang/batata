defmodule BatataTest do
  use ExUnit.Case
  doctest Batata

  test "greets the world" do
    assert Batata.hello() == :world
  end
end
