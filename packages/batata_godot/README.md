# Batata Godot

`batata_godot` is an independent Mix package for generating fail-closed Godot
GDExtension bindings around Batata-compiled functions.

The first slice defines the compile-time boundary. It validates a closed set
of scalar method signatures and emits a canonical binding plan with a stable
SHA-256 digest. It does not yet generate a native adapter or shared library.

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

The plan records the extension and entry symbol, Godot compatibility minimum,
initialization level, class inheritance, method signatures, and Batata native
symbols. Method ordering and JSON field ordering are deterministic.

Only `:nil`, `:bool`, `:int`, and `:float` are accepted in the initial schema.
Strings, containers, objects, closures, PIDs, and references are rejected until
their ownership and lifetime codecs exist. Failures use
`Batata.Godot.Diagnostic` with stable `E_GODOT_*` codes and JSON-ready context
and recovery actions.

Next, the binding plan will drive a generated Zig adapter, a platform shared
library, a `.gdextension` resource, and a real `godot --headless` load test.

Inside the Batata monorepo, select the root checkout explicitly before running
package tasks:

```sh
export BATATA_PATH=../..
mix deps.get
mix test
```

Without `BATATA_PATH`, the package uses the published `batata ~> 0.1.0`
dependency so its Hex metadata remains independently publishable.
