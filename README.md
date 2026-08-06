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
- execution (pending): ExecutionEngine, then AOT `lib<Module>.a` + C driver.

## Dev setup

Beaver and Kinda are pre-release, so development uses local checkouts:

```sh
export BEAVER_PATH=/path/to/beaver
export BEAVER_KINDA_PATH=/path/to/kinda
mix deps.get
mix test
```
