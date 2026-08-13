defmodule Batata.Probe.Decimal.SourceTest do
  use ExUnit.Case, async: true

  test "pins Decimal 2.3.0 to an immutable upstream commit" do
    metadata = "probe/decimal/source.json" |> File.read!() |> JSON.decode!()

    assert metadata == %{
             "name" => "decimal",
             "repository" => "https://github.com/ericmj/decimal.git",
             "ref" => "v2.3.0",
             "commit" => "592d59ac4474933f91cdc3e8e037f137f7e008b0"
           }
  end
end
