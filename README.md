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
