# Batata Godot

`batata_godot` is an independent Mix package for generating fail-closed Godot
GDExtension bindings around Batata-compiled functions.

The package validates a closed set of scalar method signatures and emits a
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
  godot_method :add, args: [:int, :int], returns: :int

  def add(a, b), do: a + b
end

plan = Batata.Godot.binding_plan(Example)
json = Batata.Godot.canonical_json(Example)
digest = Batata.Godot.digest(Example)
```

Build the first macOS arm64 artifact with Godot 4.6.2 and Zig 0.16:

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
initialization level, class inheritance, method signatures, and Batata native
symbols. Method ordering and JSON field ordering are deterministic.

Only `:nil`, `:bool`, `:int`, and `:float` are accepted in the initial schema.
Strings, containers, objects, closures, PIDs, and references are rejected until
their ownership and lifetime codecs exist. Failures use
`Batata.Godot.Diagnostic` with stable `E_GODOT_*` codes and JSON-ready context
and recovery actions.

The generated bundle records the binding-plan, fixed adapter implementation,
native artifact and Godot API digests, target triple, entry symbol, compiler
versions, and a sorted artifact index. The pinned raw interface is Godot 4.6.2
`gdextension_interface.json`, SHA-256
`34d7058f31af186d36b84567e70a9f9543da0d74f25cfe5266d4fe2d27e090f0`.

This target deliberately registers no class yet. The next slice will add the
`RefCounted` ClassDB registration and the first `int -> int` call trampoline;
until then, successful loading does not claim that declared methods are
callable from Godot.

Inside the Batata monorepo, select the root checkout explicitly before running
package tasks:

```sh
export BATATA_PATH=../..
mix deps.get
mix test
```

Without `BATATA_PATH`, the package uses the published `batata ~> 0.1.0`
dependency so its Hex metadata remains independently publishable.
