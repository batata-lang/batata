defmodule Batata.Wings.FoundationTest do
  use ExUnit.Case, async: true

  alias Batata.Wings.{CanonicalJSON, Diagnostic, Mesh, Vec3}

  test "vector operations preserve the upstream e3d orientation" do
    assert Vec3.cross({1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}) == {0.0, 0.0, 1.0}
    assert Vec3.dot({1.0, 2.0, 3.0}, {4.0, 5.0, 6.0}) == 32.0
    assert Vec3.average([{1.0, 0.0, 0.0}, {3.0, 2.0, 0.0}]) == {2.0, 1.0, 0.0}
    assert Vec3.normalize({0.0, 0.0, 0.0}) == Vec3.zero()
  end

  test "canonical mesh JSON and digest ignore map insertion order" do
    left =
      Mesh.new!(
        %{2 => {0.0, 1.0, 0.0}, 0 => {0.0, 0.0, 0.0}, 1 => {1.0, 0.0, 0.0}},
        %{0 => [0, 1, 2]},
        %{"source" => "fixture", "closed" => false}
      )

    right =
      Mesh.new!(
        Map.new([{1, {1.0, 0.0, 0.0}}, {0, {0.0, 0.0, 0.0}}, {2, {0.0, 1.0, 0.0}}]),
        Map.new([{0, [0, 1, 2]}]),
        Map.new([{"closed", false}, {"source", "fixture"}])
      )

    assert Batata.Wings.canonical_json(left) == Batata.Wings.canonical_json(right)
    assert Batata.Wings.digest(left) == Batata.Wings.digest(right)

    assert JSON.decode!(Batata.Wings.canonical_json(left))["faces"] == [
             %{"id" => 0, "vertices" => [0, 1, 2]}
           ]
  end

  test "canonical JSON rejects atom and string keys that collapse together" do
    assert_raise ArgumentError, ~r/duplicate key "source"/, fn ->
      CanonicalJSON.encode!(%{:source => "atom", "source" => "string"})
    end
  end

  test "mesh construction fails closed on dangling vertex references" do
    error =
      assert_raise Diagnostic, fn ->
        Mesh.new!(%{0 => {0.0, 0.0, 0.0}}, %{0 => [0, 1, 2]})
      end

    assert error.code == "E_WINGS_TOPOLOGY_INCONSISTENT"
    assert Exception.message(error) |> JSON.decode!() |> Map.fetch!("code") == error.code
  end

  test "provenance pins upstream and source mapping" do
    provenance = Batata.Wings.provenance()

    assert provenance["upstream"] == "https://github.com/dgud/wings"
    assert provenance["upstream_commit"] == "e12ef3ce267c4d9ecb33d4845bdc9275f1a4b433"
    assert provenance["source_mapping"]["src/wings_we.erl"] == "Batata.Wings.Topology"
  end
end
