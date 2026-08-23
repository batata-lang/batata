defmodule Batata.Godot.AdapterTest.Extension do
  use Batata.Godot.Extension,
    extension: "adapter_fixture",
    compatibility_minimum: "4.6",
    initialization_level: :scene

  godot_class("AdapterFixture", base: "RefCounted")
  godot_method(:add, args: [:int, :int], returns: :int)

  def add(left, right), do: left + right
end

defmodule Batata.Godot.AdapterTest do
  use ExUnit.Case, async: true

  alias Batata.Godot.Adapter
  alias Batata.Godot.AdapterTest.Extension

  test "Zig adapter exports the configured raw ABI entry point" do
    source = Extension |> Batata.Godot.binding_plan() |> Adapter.zig_source()

    assert source =~ ~s|@export(&extensionEntry, .{ .name = "adapter_fixture_library_init" })|
    assert source =~ ".minimum_initialization_level = 2"
    assert source =~ ".initialize = &initialize"
    assert source =~ ".deinitialize = &deinitialize"
    refute source =~ "classdb_register"
  end

  test "adapter generation is deterministic" do
    plan = Batata.Godot.binding_plan(Extension)

    digest =
      plan
      |> Adapter.zig_source()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert Adapter.zig_source(plan) == Adapter.zig_source(plan)
    assert digest == "41fde6edf7efd3fa0453c29c625f8c8d54dfaef6df4f96b84f0247a2bb43c002"
  end

  @tag :tmp_dir
  test "generated adapter compiles as a dynamic library", %{tmp_dir: tmp_dir} do
    zig = System.find_executable("zig") || raise "zig not found on PATH"
    source_path = Path.join(tmp_dir, "adapter.zig")
    library_path = Path.join(tmp_dir, dynamic_library_name())
    File.write!(source_path, Extension |> Batata.Godot.binding_plan() |> Adapter.zig_source())

    {output, status} =
      System.cmd(
        zig,
        [
          "build-lib",
          "-dynamic",
          "--cache-dir",
          Path.join(tmp_dir, "zig-cache"),
          "-femit-bin=#{library_path}",
          source_path
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert File.regular?(library_path)

    assert :ok =
             Batata.Export.verify_symbols!(library_path, [
               %{"symbol" => "adapter_fixture_library_init"}
             ])
  end

  test "Batata runtime source resolves independently of the package working directory" do
    assert Batata.TermRuntime.native_dir()
           |> Path.join("term_runtime.zig")
           |> File.regular?()
  end

  test "GDExtension resource is pinned to the initial platform surface" do
    resource =
      Extension
      |> Batata.Godot.binding_plan()
      |> Adapter.gdextension_source("libadapter_fixture.macos.debug.arm64.dylib")

    assert resource =~ ~s|entry_symbol = "adapter_fixture_library_init"|
    assert resource =~ ~s|compatibility_minimum = "4.6"|
    assert resource =~ "reloadable = false"

    assert resource =~
             ~s|macos.debug.arm64 = "res://bin/libadapter_fixture.macos.debug.arm64.dylib"|
  end

  defp dynamic_library_name do
    case :os.type() do
      {:unix, :darwin} -> "libadapter.dylib"
      {:unix, _name} -> "libadapter.so"
      {:win32, _name} -> "adapter.dll"
    end
  end
end
