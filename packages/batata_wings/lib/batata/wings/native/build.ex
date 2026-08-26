defmodule Batata.Wings.Native.Build do
  @moduledoc "Builds and proves the checked-in Wings native kernel AOT unit."

  alias Batata.Wings.CanonicalJSON
  alias Batata.Wings.Native.Source

  @functions [
    {:topology_code_for_state, 1},
    {:select_face, 3},
    {:move_selected, 6},
    {:generation, 1},
    {:vertices, 1},
    {:faces, 1},
    {:selection, 1},
    {:vertex_position, 2}
  ]

  @doc "Compiles the real kernel source and writes a source/function/artifact receipt."
  @spec build!(Path.t(), Beaver.MLIR.Context.t(), keyword()) :: map()
  def build!(output_dir, ctx, options \\ []) do
    native = Batata.build(Source.read!(), output_dir, ctx, options)
    functions = Enum.map(@functions, &function_entry/1)
    Batata.Export.verify_symbols!(native.archive, functions)

    receipt = %{
      "artifact_sha256" => digest_file(native.object),
      "archive_sha256" => digest_file(native.archive),
      "functions" => functions,
      "kind" => "batata_wings_native_kernel",
      "schema_version" => 1,
      "source" => Source.identity(),
      "target" => :erlang.system_info(:system_architecture) |> List.to_string()
    }

    receipt_path = Path.join(output_dir, "wings_native_receipt.json")
    File.write!(receipt_path, CanonicalJSON.encode!(receipt))

    Map.merge(native, %{receipt: receipt_path})
  end

  defp function_entry({name, arity}) do
    %{
      "arity" => arity,
      "name" => Atom.to_string(name),
      "symbol" => Batata.Symbol.function(name, arity)
    }
  end

  defp digest_file(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
