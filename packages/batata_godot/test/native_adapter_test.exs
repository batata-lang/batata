defmodule Batata.Godot.NativeAdapterTest.Extension do
  use Batata.Godot.Extension,
    extension: "adapter_fixture",
    compatibility_minimum: "4.6",
    initialization_level: :scene

  godot_class("AdapterFixture", base: "RefCounted")
  godot_method(:add, args: [:int, :int], returns: :int)

  def add(left, right), do: left + right
end

defmodule Batata.Godot.NativeAdapterTest do
  use ExUnit.Case, async: true

  alias Batata.Godot.NativeAdapterTest.Extension
  alias Batata.Godot.{Platform, Resource}

  test "checked-in adapter uses the comptime term runtime extension contract" do
    source = File.read!(Path.join(native_build_root(), "native/zig-src/main.zig"))

    assert source =~ "term_runtime.Extension"
    assert source =~ ".namespace = @This()"
    assert source =~ "build_options.entry_symbol"
    assert source =~ "build_options.initialization_level"
    assert source =~ "api.classdb_register_extension_class5"
    assert source =~ "api.classdb_unregister_extension_class"
    assert source =~ "build_options.class_name"
    assert source =~ "build_options.base_class_name"
    assert source =~ "packedVector3ArrayToTerm"
    assert source =~ "writeArrayMeshObjectResult"
    assert source =~ "E_GODOT_INSTANCE_STATE_STALE"
    refute source =~ "ex_term_runtime_create();\n    if (runtime_handle <= 0 or"

    godot_abi = File.read!(Path.join(native_build_root(), "native/zig-src/godot.zig"))
    assert godot_abi =~ "GDExtensionClassCreationInfo5"
    assert godot_abi =~ "classdb_register_extension_class5"
    assert godot_abi =~ "packed_vector3_array_operator_index"
    assert godot_abi =~ "object_method_bind_ptrcall"
  end

  test "Batata runtime extension source resolves independently of package cwd" do
    assert Batata.TermRuntime.native_dir()
           |> Path.join("extension.zig")
           |> File.regular?()
  end

  test "GDExtension resource carries the closed platform feature table" do
    assert Platform.supported_targets() == [
             "aarch64-apple-darwin",
             "x86_64-apple-darwin",
             "x86_64-linux-gnu",
             "x86_64-pc-windows-msvc"
           ]

    resource =
      Extension
      |> Batata.Godot.binding_plan()
      |> Resource.gdextension_source(Platform.library_table("adapter_fixture"))

    assert resource =~ ~s|entry_symbol = "adapter_fixture_library_init"|
    assert resource =~ ~s|compatibility_minimum = "4.6"|
    assert resource =~ "reloadable = false"

    assert resource =~
             ~s|macos.debug.arm64 = "res://bin/libadapter_fixture.macos.debug.arm64.dylib"|

    assert resource =~
             ~s|macos.debug.x86_64 = "res://bin/libadapter_fixture.macos.debug.x86_64.dylib"|

    assert resource =~
             ~s|linux.debug.x86_64 = "res://bin/libadapter_fixture.linux.debug.x86_64.so"|

    assert resource =~
             ~s|windows.debug.x86_64 = "res://bin/adapter_fixture.windows.debug.x86_64.dll"|
  end

  defp native_build_root do
    :batata_godot
    |> Application.app_dir("priv")
    |> canonical_path()
    |> Path.dirname()
  end

  defp canonical_path(path) do
    case File.read_link(path) do
      {:ok, resolved} ->
        case Path.type(resolved) do
          :absolute -> resolved
          :relative -> Path.expand(resolved, Path.dirname(path))
        end

      {:error, _reason} ->
        Path.expand(path)
    end
  end
end
