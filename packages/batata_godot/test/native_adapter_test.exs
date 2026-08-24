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
  alias Batata.Godot.Resource

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

    godot_abi = File.read!(Path.join(native_build_root(), "native/zig-src/godot.zig"))
    assert godot_abi =~ "GDExtensionClassCreationInfo5"
    assert godot_abi =~ "classdb_register_extension_class5"
  end

  test "Batata runtime extension source resolves independently of package cwd" do
    assert Batata.TermRuntime.native_dir()
           |> Path.join("extension.zig")
           |> File.regular?()
  end

  test "GDExtension resource is pinned to the initial platform surface" do
    resource =
      Extension
      |> Batata.Godot.binding_plan()
      |> Resource.gdextension_source("libadapter_fixture.macos.debug.arm64.dylib")

    assert resource =~ ~s|entry_symbol = "adapter_fixture_library_init"|
    assert resource =~ ~s|compatibility_minimum = "4.6"|
    assert resource =~ "reloadable = false"

    assert resource =~
             ~s|macos.debug.arm64 = "res://bin/libadapter_fixture.macos.debug.arm64.dylib"|
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
