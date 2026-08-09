# Batata

An Elixir-to-native compiler built on
[Beaver](https://github.com/beaver-lodge/beaver) and the Slang-defined `ex`
dialect.

## Scope

The first milestone wires a minimal closed loop (see
[tsai/beaver#6](https://localhost:3000/tsai/beaver/issues/6) for the plan):

- frontend: expanded module snapshot → `ex` IR (boundary only, no macro semantics);
- lowering: `ex` → `func`/`arith`/`scf`/`cf` → LLVM via
  `Beaver.MLIR.Conversion.Plan` (the conversion patterns themselves live in
  Beaver) — `Batata.to_llvm/2` runs the plan plus the standard
  `arith-to-llvm` / `func-to-llvm` passes;
- execution: ExecutionEngine (JIT) — `Batata.execute/2` lowers the source and
  runs `main` through the MLIR JIT; AOT — `Batata.build/3` emits
  `lib<Module>.a` plus a C driver that calls the entry function.

M2 adds the first slice of the term universe on top (see
[tsai/beaver#17](https://localhost:3000/tsai/beaver/issues/17)):

- a Zig term runtime (`native/term_runtime.zig`) implementing the
  declaration-first ABI in `native/ABI.md` (tagged word + bump heap);
- lowering of `ex.tuple`/`ex.list`/`ex.map`/`ex.binary` construction and the
  `ex.is_*` predicates to `ex.term.*` runtime calls (the patterns live in
  Beaver, `Beaver.MLIR.Conversion.Ex`);
- JIT execution of term construction and predicates through the runtime
  shared library (`Batata.execute/2` attaches it via `shared_lib_paths`).

The pipeline now has an explicit transform layer between lift and lowering
(see [tsai/beaver#16](https://localhost:3000/tsai/beaver/issues/16)):

- `Batata.Transform` is the information-preserving IR-to-IR rewrite layer;
  anything that changes representation or drops information belongs in
  `Batata.Lower` (discipline transplanted from expandable);
- `Batata.Transform.InlineScalarCalls` inlines local calls whose callee stays
  in the scalar slice, so `ex.call` results (typed `!ex.dyn`) can feed
  arithmetic — e.g. `add(1, 2) + 3` compiles to 6.

M3 starts the stdlib domain registry (see
[tsai/beaver#6](https://localhost:3000/tsai/beaver/issues/6)):

- `Batata.Stdlib` declares which `{module, function, arity}` entries are
  natively replaceable (`:native_term`), which await the BEAM callback bridge
  (`:beamer_callback`, e.g. `Enum`), and which are declared-but-unlowered
  (`:unsupported`); anything outside the surface raises explicitly at lift;
- module-qualified calls (`Kernel.length/1`, `List.first/1`, ...) and
  auto-imported Kernel BIFs (`length/1`, `hd/1`, `elem/2`, `map_size/1`, ...)
  resolve through the registry and lower to `ex.term.*` runtime intrinsics;
- the first slice added `ex.map_length` (`map_size`/`Map.size`) to the Zig
  runtime, completing the read-intrinsic family for tuple/list/map/binary.

The Enum slice adds the first callback-shaped stdlib calls:

- `Enum.count/1` lowers to `ex.term.enumerable_count`, dispatching on the
  term tag (list/tuple/map/binary);
- `Enum.map/2` with an identity mapper and `Enum.reduce/3` with
  sum/return-accumulator reducers are recognized before closure extraction and
  lower to `scf.while` cursor loops over the list (`ex.list_get` +
  `ex.to_int`); const mappers (`fn _x -> c end`) and capture-add mappers
  (`fn x -> x + c end`, literal or captured scalar) lower to descending
  cons-collection loops (`ex.list_cons`); other mapper/reducer shapes keep the
  explicit `:beamer_callback` rejection; sum reduce over non-list
  enumerables (tuple/binary literals or variables) dispatches through the
  runtime's tag-based `ex.term.enumerable_reduce`; map reduce with a
  `fn {_k, v}, acc -> acc + v end` value-sum reducer dispatches through the
  same runtime (continuation 3), and `fn {k, _v}, acc -> acc + k end`
  key-sum through continuation 4.

The String/Base slice adds UTF-8 and byte-string conversions in the Zig
runtime:

- `String.length/1` (`ex.term.binary_utf8_length`, codepoint count) and
  `String.to_integer/1` / `Integer.to_string/1` (decimal round-trip);
- `Base.encode16/1` / `Base.decode16/1` (uppercase hex, `ex.term.binary_encode16`
  / `ex.term.binary_decode16`); invalid hex decodes to nil.

M5 starts the `native_elixirc` equivalent (see
[tsai/beaver#29](https://localhost:3000/tsai/beaver/issues/29)):

- `Batata.build/3` now emits an export bundle (`bundle.json`,
  `artifact_index.json`, `manifest.json`) with module/entry/source digest/
  runtime version/artifact digest and a per-file digest index, plus a
  symbol-level `exports` list (every definition's `Module.fun/arity` and its
  native symbol, entry renamed to `batata_main`); `Export.verify_symbols!/2`
  checks the symbols against the archive via `nm`;
- `Batata.Upgrade.Diff.compare/2` compares two bundle directories and reports
  file additions/removals/changes, `artifacts_changed`, and
  `migration_required` (artifact change implies migration), plus a bundle
  `schema_drift` (field set and schema version: unchanged / changed /
  incompatible);
- `test/semantic_gates_test.exs` runs a gate per slice (scalar, term
  patterns, cursor scanners, Kernel/Enum/String/Base stdlib, closures,
  receive, try/throw), asserting Batata's compiled result matches the BEAM
  oracle of the equivalent expression;
- `test/fixtures/self_bootstrap.exs` is a self-bootstrap fixture: a
  batata-shaped module (stand-in for `Upgrade.Diff`'s status classification)
  that is compiled by Batata, checked against the BEAM oracle, and built into
  a runnable AOT binary with verified symbols (`zig cc` links the Zig term
  runtime).

Protocol consolidation starts with the native provider layer:

- `Batata.Native.Provider` is a `defprotocol` extension point
  (`native_plan/1`, `@fallback_to_any true`); project-local IR nodes
  contribute replacement plans through `defimpl`, and consolidation exposes
  the closed-world provider set at compile time (`Registry.impls/0`);
- `Batata.Stdlib.Plan` carries the replacement class (`:native_term` /
  `:beamer_callback` / `:unsupported`) for an `{module, function, arity}`;
  `Batata.Stdlib.plan/1` mirrors the built-in registry as a plan.

## Dev setup

## Dev setup

Beaver and Kinda are pre-release, so development uses local checkouts:

```sh
export BEAVER_PATH=/path/to/beaver
export BEAVER_KINDA_PATH=/path/to/kinda
mix deps.get
mix test
```

The Zig runtime is built on demand with `zig build-lib` (zig 0.16 is required
and preinstalled in CI).
