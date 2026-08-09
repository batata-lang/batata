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
  key-sum through continuation 4; `fn {k, v}, acc -> acc + k + v end`
  (any addition order) sums key and value per entry through continuation 5;
  product reducers (`fn x, a -> x * a end`) use the cursor loop for list
  literals and runtime continuation 6 otherwise; subtraction is
  order-sensitive (`a - x` vs `x - a`, runtime continuations 7/8); arbitrary
  arithmetic combination reducers (e.g. `a + x * 2`) compile the reducer body
  into the cursor loop for list literals; integer `div/2` and `rem/2`
  reducers (order-sensitive, zero divisor yields 0) dispatch through runtime
  continuations 9-12; capture-sum reducers (`fn x, a -> a + x + c end`, c a
  captured scalar or literal) dispatch through `ex.term.enumerable_reduce_c`
  (continuation 13), capture-product (`a + x * c`, continuation 14) likewise;
  range literals (`1..3`) reduce through `ex.term.enumerable_reduce_range`
  (scalar reducers and count; combination/map shapes raise); arbitrary
  combination reducers are extracted to synthetic functions and called by the
  runtime through function pointers (`ex.term.enumerable_reduce_fun`),
  supporting list/tuple/binary for any pure-arithmetic reducer body.

Protocol dispatch follows the expandable route (native callbacks, no BEAM
bridge — see [tsai/beaver#30](https://localhost:3000/tsai/beaver/issues/30)):

- `Batata.Native.Enumerable` records the consolidated `Enumerable` impls
  (internal term-tag dispatch for List/Map/Range plus the batata Tuple/Binary
  extensions; external impls listed for explicit rejection);
- the Zig runtime exposes a native callback registry
  (`ex.term.register_callback` / `ex.term.call_callback`) for compiled impls,
  the building block for external-type count/reduce dispatch;
- `Batata.Native.Enumerable.compile_plan/1` classifies each consolidated impl:
  internal types get `:runtime_tag` count/reduce, external impls (Stream,
  MapSet, Function, ...) get `:unsupported` with a reason (their Elixir
  implementations are outside the slice — MISSING_IMPL discipline);
  `register_native/2` maps an external impl to runtime callback slots for a
  project-provided Provider plan;
- slice extension: `Enum.to_list/1` is native (`ex.term.enumerable_to_list`
  by term tag: list identity, tuple elements, map `{k, v}` pairs, binary
  bytes, plus range via `ex.term.enumerable_to_list_range`) — the first
  external-impl callback (to_list) moved from BEAM to native dispatch;
  arbitrary arithmetic mappers (`fn x -> x * 2 end`) now compile to synthetic
  functions called through `ex.term.enumerable_map_fun` for any
  list/tuple/binary; reduce bodies generalize beyond arithmetic trees — any
  slice-compilable expression over item/acc (including `div`/`rem`, now
  `ex.div`/`ex.rem`, and comparisons) compiles into the extracted reducer;
- slice extension for sets: `MapSet.new/1` / `member?/2` / `put/2` (and
  `HashSet.new/1`) compile to deduplicated list words
  (`ex.term.mapset_*`), so `Enum` operations over sets reuse the list paths —
  the first external Enumerable impl native-ized via a slice representation;
  `Stream.map/2` and `Stream.filter/2` compile eagerly (mapper/predicate
  extracted to synthetic functions, `ex.term.stream_filter` for filtering) —
  for side-effect-free streams the eager result matches consumption;
  `Stream.take/2` and `Stream.drop/2` slice lists in the runtime
  (`ex.term.stream_take` / `stream_drop`);
  dates are gregorian/ISO days (i64): `Date.new(y, m, d)` with integer
  literals folds at lift time (`Calendar.ISO.date_to_iso_days/3`), so date
  ranges (`Date.new(..)..Date.new(..)`) reuse the integer range paths
  (`Enum.count/reduce/to_list`), including leap-day differences;
  file IO: `File.read!/1` and `File.stream!/1` read through the runtime
  (`ex.term.file_read` / `file_read_lines`, eager lines).

The actor model (tsai/beaver#35) starts with the Zig process and reduction
clock:

- a single `Process` holds pid, FIFO mailbox, and `Clock{budget, used, epoch}`
  (the mailbox moved from globals into the process);
- clock primitives (`ex.term.clock_init` / `clock_tick` / `clock_budget_left` /
  `clock_epoch` / `clock_bump_epoch`) charge reductions and expose the
  continuation-generation counter, ready for loop back-edge injection and
  preemptive yield;
- slice 2: `ex.reduction_tick` is injected into every `scf.while` back edge
  (once per iteration); with `Batata.execute/3`'s `reduction_budget` option
  an exhausted budget saves the cursor-loop continuation and exits the loop
  (a real preemptive yield); without a budget the tick is a no-op;
- slice 5: the generated scheduler driver (`main`) runs a process table:
  `spawn(fun)` registers a closure entry, the driver round-robins runnable
  processes and resumes a preempted process from its saved continuation
  (`cont_save`/`cont_pending`/`cont_load_*`), and `process_done` parks a
  completed process with its result. Post-loop body (e.g. `receive`) is gated
  on loop completion, so side effects never repeat across slices. Message
  delivery does not invalidate continuations in this slice (a plain FIFO
  receive must observe it on resume); `clock_bump_epoch` remains the explicit
  invalidation primitive.

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
