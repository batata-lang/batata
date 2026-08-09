# Batata Release Readiness

This playbook turns the current milestone status into a repeatable release gate.

## 1) Release target and scope freeze

Choose one target per cycle:

- **Technical preview (`0.x`)**: feature-complete for the declared surface, with known limitations documented.
- **Stable (`1.0`)**: compatibility commitments plus broader semantic coverage.

Scope freeze means no new stdlib domains or ABI symbols after freeze starts, only fixes.

## 2) Dependency stability policy (Beaver / Kinda)

Beaver and Kinda are still pre-release. For each release candidate:

1. Pin `BEAVER_REF` in CI to an explicit ref.
2. Record the tested Beaver/Kinda refs in release notes.
3. Keep a rollback candidate from the previous green ref.

For stacked PRs, set `BEAVER_REF` **before** opening/updating the PR.

## 3) Language and stdlib boundary freeze

`Batata.Stdlib` is the source of truth for declared surface:

- `:native_term` => must compile and run through runtime/lowering.
- `:beamer_callback` => must fail with explicit callback-interop error when unsupported.
- `:unsupported` => must fail with explicit declared-but-unlowered error.

Release gate requires boundary behavior to be explicit and covered by tests.

## 4) Correctness gate policy

`test/semantic_gates_test.exs` is the release gate suite. Failures are triaged as:

- **Blocking**: wrong result vs BEAM oracle, crash, ABI mismatch, or silent behavior change.
- **Defer-capable**: non-critical perf regressions or diagnostics wording only (no semantic change).

Any blocking failure stops release.

## 5) Runtime/ABI lockstep gate

Before release:

1. Verify `native/ABI.md` and `native/term_runtime.zig` are lockstep for all declared intrinsics.
2. Verify JIT (`Batata.execute/2`) and AOT (`Batata.build/3`) run equivalent scenarios.

Any missing/renamed intrinsic is blocking.

## 6) Packaging and artifact acceptance

Release candidate must pass:

```sh
mix format --check-formatted
mix test
env -u BEAVER_PATH -u BEAVER_KINDA_PATH MIX_ENV=test mix hex.build
```

Also verify export bundle outputs and symbol checks (`Batata.Export.verify_symbols!/2`) for AOT artifacts.

## 7) CI release threshold

CI must enforce:

- formatting check,
- full test suite,
- Hex package build simulation.

CI also warns when PRs run with default `BEAVER_REF=main`, to catch stacked-PR drift risk early.

## 8) External release contract

Each release notes document must include:

- supported syntax/stdlib/runtime capabilities,
- known limitations,
- compatibility and upgrade expectations.

## 9) Dry-run procedure

Run 1-2 dry-runs per release candidate:

1. Start from release branch/tag candidate.
2. Execute full CI-equivalent commands locally.
3. Validate install/build path from a clean checkout.
4. Confirm no undocumented manual step is required.

## Timeline back-planning (rough)

- **Technical preview (`0.x`)**: ~2-6 weeks (scope freeze + dry-runs + docs).
- **Stable (`1.0`)**: ~3-6 months (coverage, dependency stability, compatibility contract).
- Add **2-8 weeks** buffer if Beaver/Kinda introduce breaking changes in-window.
