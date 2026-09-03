defmodule Batata.Wings.Godot.SignatureContractTest do
  use ExUnit.Case, async: true

  test "native editor exports keep state terms and Godot integers on the scalar ABI" do
    source =
      Path.expand(
        "../../batata_wings/lib/batata/wings/native/kernel.ex",
        __DIR__
      )
      |> File.read!()

    signatures =
      source |> Batata.Frontend.from_source() |> then(&Batata.Signature.infer(&1.definitions))

    assert Map.take(signatures, Map.keys(expected_signatures())) == expected_signatures()
  end

  defp expected_signatures do
    %{
      {:mesh, 1} => [:term],
      {:state_generation, 1} => [:term],
      {:editor_layout_code, 1} => [:term],
      {:displayed_mesh_code, 1} => [:term],
      {:selected_triangle_indices, 1} => [:term],
      {:editor_pointer_button, 8} => [:term | List.duplicate(:scalar, 7)],
      {:editor_move, 6} => [:term | List.duplicate(:scalar, 5)],
      {:editor_extrude, 4} => [:term | List.duplicate(:scalar, 3)],
      {:editor_extrude_individual, 4} => [:term | List.duplicate(:scalar, 3)],
      {:editor_inset, 4} => [:term | List.duplicate(:scalar, 3)],
      {:editor_bevel, 5} => [:term | List.duplicate(:scalar, 4)],
      {:editor_undo, 2} => [:term, :scalar],
      {:editor_redo, 2} => [:term, :scalar]
    }
  end
end
