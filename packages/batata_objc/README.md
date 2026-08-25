# Batata Objective-C

`batata_objc` is a fail-closed Objective-C bridge for Batata. Its first closed
surface is macOS AppKit. Bindings are target-specific data consumed by a fixed
native adapter; Batata does not generate Zig source and does not expose
arbitrary selector dispatch.

The checked-in metadata allowlist records selector types, ownership,
nullability and thread requirements. A canonical binding plan and SHA-256
digest make every accepted boundary replayable. Unknown SDK metadata, ABI,
ownership or callback signatures are errors instead of dynamic fallbacks.
The plan distinguishes the SDK used to review metadata from the compatibility
floor; every build receipt records the actual installed SDK, while versions
below the floor fail closed.

The native boundary uses typed `objc_msgSend` signatures, generation-checked
object handles, same-thread autorelease tokens and a checked-in Objective-C
exception fence. Every external selector also receives a deterministic memory
effect summary; unknown effects cannot silently pass Batata's memory verifier.

The AppKit slice generates a complete `.app` bundle and closes one real event
loop: `NSApplicationDelegate.applicationDidFinishLaunching:`, `NSWindow`, a
label and button, AppKit target-action into compiled Batata, termination policy,
and deterministic release. The smoke launches the executable under the active
WindowServer and requires all callback markers plus a clean exit.

Cross-thread work has one operation: dispatch a declared callback to the main
queue. The initial Apple Block surface is likewise one `void (^)(void *)`
shape with tested copy/dispose hooks. Arbitrary queues and Block signatures
remain closed. Native tests also ask the installed Objective-C runtime for the
method encoding of every MVP selector family, so an unavailable selector does
not survive as a link-only claim.

Inside the Batata monorepo:

```sh
export BATATA_PATH=../..
mix deps.get
mix test
```
