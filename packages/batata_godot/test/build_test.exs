defmodule Batata.Godot.BuildTest.Extension do
  use Batata.Godot.Extension,
    extension: "batata_load_smoke",
    compatibility_minimum: "4.6.2",
    initialization_level: :scene

  godot_class("BatataLoadSmoke", base: "RefCounted")
  godot_method(:add, args: [:int, :int], returns: :int)
  godot_method(:bool_identity, args: [:bool], returns: :bool)
  godot_method(:float_identity, args: [:float], returns: :float)
  godot_method(:nil_identity, args: [nil], returns: nil)
  godot_method(:string_identity, args: [:string], returns: :string)
  godot_method(:string_name_identity, args: [:string_name], returns: :string_name)
  godot_method(:vector2_identity, args: [:vector2], returns: :vector2)
  godot_method(:vector3_identity, args: [:vector3], returns: :vector3)

  godot_method(:object_identity,
    args: [{:object, "RefCounted"}],
    returns: {:object, "RefCounted"}
  )

  def add(left, right), do: left + right
  def bool_identity(value), do: value
  def float_identity(value), do: value
  def nil_identity(value), do: value
  def string_identity(value), do: value
  def string_name_identity(value), do: value
  def vector2_identity(value), do: value
  def vector3_identity(value), do: value
  def object_identity(value), do: value
end

defmodule Batata.Godot.BuildTest do
  use ExUnit.Case, async: true

  alias Batata.Godot.BuildTest.Extension

  @darwin_arm64 match?({:unix, :darwin}, :os.type()) and
                  :erlang.system_info(:system_architecture)
                  |> List.to_string()
                  |> String.starts_with?("aarch64-")

  if @darwin_arm64 do
    alias Beaver.MLIR.Context

    @moduletag timeout: 180_000

    @tag :tmp_dir
    test "builds, verifies, loads and unloads the initial GDExtension", %{tmp_dir: tmp_dir} do
      ctx = Context.create()
      on_exit(fn -> Context.destroy(ctx) end)

      output =
        Batata.Godot.build(
          """
          defmodule GodotLoadSmoke do
            def main(), do: 0
            def add(left, right), do: left + right
            def bool_identity(value), do: value
            def float_identity(value), do: value
            def nil_identity(value), do: value
            def string_identity(value), do: value
            def string_name_identity(value), do: value
            def vector2_identity(value), do: value
            def vector3_identity(value), do: value
            def object_identity(value), do: value
          end
          """,
          Extension,
          tmp_dir,
          ctx,
          smoke: [
            %{method: "add", arguments: [20, 22], expected: 42, repeat: 32},
            %{method: "bool_identity", arguments: [true], expected: true},
            %{method: "float_identity", arguments: [2.25], expected: 2.25},
            %{method: "nil_identity", arguments: [nil], expected: nil},
            %{
              method: "string_identity",
              arguments: ["Batata 蝙蝠"],
              expected: "Batata 蝙蝠"
            },
            %{
              method: "string_name_identity",
              arguments: ["batata_action"],
              expected: "batata_action"
            },
            %{
              method: "vector2_identity",
              arguments: [[1.25, -2.5]],
              expected: [1.25, -2.5]
            },
            %{
              method: "vector3_identity",
              arguments: [[1.25, -2.5, 3.75]],
              expected: [1.25, -2.5, 3.75]
            },
            %{
              method: "object_identity",
              arguments: [:self],
              expected: :self
            }
          ]
        )

      for path <- [
            output.library,
            output.gdextension,
            output.binding_plan,
            output.bundle,
            output.artifact_index,
            output.manifest
          ] do
        assert File.regular?(path)
      end

      bundle = output.bundle |> File.read!() |> JSON.decode!()
      index = output.artifact_index |> File.read!() |> JSON.decode!()
      manifest = output.manifest |> File.read!() |> JSON.decode!()

      assert bundle["kind"] == "godot_gdextension"
      assert bundle["entry_symbol"] == "batata_load_smoke_library_init"
      assert bundle["godot_api_version"] == "4.6.2"
      assert bundle["target"] == "aarch64-apple-darwin"
      assert byte_size(bundle["binding_plan_sha256"]) == 64
      assert byte_size(bundle["adapter_implementation_sha256"]) == 64
      assert manifest["zig"] =~ ~r/^0\.16\./
      assert length(index["files"]) == 3
      assert Path.wildcard(Path.join(tmp_dir, "**/*.zig"), match_dot: true) == []

      smoke_script = Path.join(tmp_dir, ".batata/godot-classdb-smoke.gd")
      assert File.read!(smoke_script) =~ ~s|ClassDB.class_exists("BatataLoadSmoke")|
      assert File.read!(smoke_script) =~ ~s|object.callv("add", [20,22])|

      assert :ok = Batata.Godot.smoke_load!(tmp_dir)
    end
  else
    test "fails closed on hosts outside the first target" do
      error =
        assert_raise Batata.Godot.Diagnostic, fn ->
          Batata.Godot.build("", Extension, "unused", :unused)
        end

      assert error.code == "E_GODOT_PLATFORM_UNSUPPORTED"
      assert error.context.supported == ["aarch64-apple-darwin"]
    end
  end
end
