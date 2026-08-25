# Batata Godot

`batata_godot` is an independent Mix package for generating fail-closed Godot
GDExtension bindings around Batata-compiled functions.

The package validates a closed set of method and class contracts and emits a
canonical binding plan with a stable SHA-256 digest. Its first native target
uses a checked-in Zig adapter and a compile-time Term Runtime extension
contract to build a GDExtension that Godot can load, initialize, deinitialize,
and unload. Batata never generates Zig source.

```elixir
defmodule Example do
  use Batata.Godot.Extension,
    extension: "batata_example",
    compatibility_minimum: "4.6"

  godot_class "BatataExample", base: "RefCounted"
  godot_outbound :array_mesh_surface
  godot_method :add, args: [:int, :int], returns: :int
  godot_method :mesh, args: [], returns: {:object, "ArrayMesh"},
    outbound: :array_mesh_surface
  godot_method :get_answer, returns: :int
  godot_method :set_answer, args: [:int]
  godot_property :answer, type: :int, getter: :get_answer, setter: :set_answer
  godot_signal :answer_changed, args: [:int]

  def add(a, b), do: a + b
end

plan = Batata.Godot.binding_plan(Example)
json = Batata.Godot.canonical_json(Example)
digest = Batata.Godot.digest(Example)
```

Build the host artifact with Godot 4.6.2 and Zig 0.16:

```elixir
output =
  Batata.Godot.build(source, Example, "_build/godot", ctx,
    smoke: true
  )

output.library
#=> "_build/godot/bin/libbatata_example.macos.debug.arm64.dylib"
```

The optional smoke invokes `godot --headless --editor`, using an explicit
`.godot/extension_list.cfg`, so successful linking alone cannot masquerade as
a loadable extension.

The plan records the extension and entry symbol, Godot compatibility minimum,
initialization level, class inheritance, methods, properties, signals, the
closed `_ready`/`_process` virtual set, and Batata native symbols. Descriptor
ordering and JSON field ordering are deterministic.

The closed value surface is `nil`, `:bool`, `:int`, `:float`, `:string`,
`:string_name`, `:vector2`, `:vector3`, `:packed_vector3_array`,
`:packed_int32_array`, `:array_mesh_surface`, and `{:object, "ClassName"}`.
Packed arrays own native copies on both sides of the call. An
`:array_mesh_surface` is exactly `{vertices, triangle_indices}` and is encoded
as a 13-slot Godot mesh array with only `ARRAY_VERTEX` and `ARRAY_INDEX` set;
it is return-only and is not an arbitrary `Array` escape hatch.

`godot_outbound :array_mesh_surface` admits one pinned method bind:
`ArrayMesh.add_surface_from_arrays`, hash `1796411378` in Godot 4.6.2. A method
using `outbound: :array_mesh_surface` returns the closed descriptor from Batata
and the adapter constructs the `ArrayMesh`. Undeclared or unknown outbound
calls fail during plan construction. Each GDExtension object owns a persistent
Term Runtime handle and generation until teardown; repeated calls re-enter the
same isolated runtime, while invocation-scoped object capabilities remain
generation checked. The instance also reserves an owned portable-state handle
for the state contract and destroys it before quiescent runtime teardown.

Other Arrays, Dictionaries, closures, PIDs, and references remain rejected.
Failures use
`Batata.Godot.Diagnostic` with stable `E_GODOT_*` codes and JSON-ready context
and recovery actions.

The generated bundle records the binding-plan, fixed adapter implementation,
native artifact and Godot API digests, target triple, entry symbol, compiler
versions, and a sorted artifact index. Each build also emits a
`platform_receipt.json` binding the target and Godot feature tag to the library
digest, plan digest, adapter digest, and API digest. The `.gdextension` resource
contains the closed library table for macOS arm64/x86_64, Linux x86_64, and
Windows x86_64. The pinned raw interface is Godot 4.6.2
`gdextension_interface.json`, SHA-256
`34d7058f31af186d36b84567e70a9f9543da0d74f25cfe5266d4fe2d27e090f0`.

CI loads each host library into pinned Godot 4.6.2 headless and calls compiled
Batata methods. A successful link alone therefore cannot satisfy the platform
gate.

Inside the Batata monorepo, select the root checkout explicitly before running
package tasks:

```sh
export BATATA_PATH=../..
mix deps.get
mix test
```

Without `BATATA_PATH`, the package uses the published `batata ~> 0.1.0`
dependency so its Hex metadata remains independently publishable.
