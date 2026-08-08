# Batata Agent Guidelines

Rules for AI agents working in this repository.

## Transform / Lower boundary

- `Batata.Transform` is the information-preserving IR-to-IR rewrite layer.
  A transform does **not** change the representation and does **not** drop
  information; anything that changes representation or drops information
  belongs in `Batata.Lower`.
- Passes rewrite `ex` IR in place through Beaver rewriters
  (`Beaver.MLIR.IRRewriter` / `Beaver.MLIR.IRMapping`) and implement
  `Batata.Transform.Pass`.
- When in doubt: an IR → IR rewrite with no semantic loss is a transform;
  an IR → target (func/arith/scf/cf → LLVM, runtime ABI, bytecode) is
  lowering.

## Tests

- All tests use `use ExUnit.Case, async: true` where possible and never mutate
  process-global or VM-global state.
