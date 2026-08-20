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

## Worktrees

Create Batata worktrees with `script/worktree-add <path> <branch>`. Before
editing or testing in an existing worktree, run `mix batata.native verify`
from `scripts/native_deps`; setup is required if verification reports stale or
missing state.

## Stacked PRs against Beaver

Batata's `native-deps.lock` is the versioned source of truth for the Beaver
revision used locally and in CI. A Batata change that depends on an unmerged
Beaver branch must commit a fetchable ref and its expected full SHA to that
lock. Never coordinate stacks through a repository-wide GitHub variable.

Merge Beaver first. Then update both `BEAVER_GIT_REF` and `BEAVER_GIT_SHA` to
the final squash-merge commit before merging Batata. The native dependency
resolver rejects a ref that no longer resolves to the committed SHA.
