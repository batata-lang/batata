# Batata Objective-C

`batata_objc` is a fail-closed Objective-C bridge for Batata. Its first closed
surface is macOS AppKit. Bindings are target-specific data consumed by a fixed
native adapter; Batata does not generate Zig source and does not expose
arbitrary selector dispatch.

The checked-in metadata allowlist records selector types, ownership,
nullability and thread requirements. A canonical binding plan and SHA-256
digest make every accepted boundary replayable. Unknown SDK metadata, ABI,
ownership or callback signatures are errors instead of dynamic fallbacks.

Inside the Batata monorepo:

```sh
export BATATA_PATH=../..
mix deps.get
mix test
```
