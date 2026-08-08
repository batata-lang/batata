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

## Stacked PRs against beaver

CI clones beaver at `vars.BEAVER_REF` (default `main`). When a batata change
depends on an unmerged beaver branch, set the variable **before** opening the
PR: the ref is resolved when the workflow run starts, so a variable set after
`gh pr create` races with the first run and silently tests against `main`.

```sh
gh variable set BEAVER_REF --repo conformal-elixir/batata --body <beaver-branch>
gh pr create ...
```

Merge order is beaver first, then batata; delete the variable afterwards:

```sh
gh variable delete BEAVER_REF --repo conformal-elixir/batata
```

If a run already started with the wrong ref (logs show `BEAVER_REF: main`),
push an empty commit to the PR branch to trigger a fresh run instead of
rerunning the old job.
