# Decimal compile probe

Decimal is a second external compile-coverage corpus for Batata. It is not a
production dependency of Batata or Beaver, and the inventory does not claim
that an accepted definition executes with Decimal semantics.

[`source.json`](source.json) pins Decimal `v2.3.0` to commit
`592d59ac4474933f91cdc3e8e037f137f7e008b0`. To reproduce the report:

```sh
git clone https://github.com/ericmj/decimal.git /tmp/batata-decimal
git -C /tmp/batata-decimal checkout 592d59ac4474933f91cdc3e8e037f137f7e008b0
mix batata.decimal_probe \
  --source /tmp/batata-decimal \
  --output _build/decimal_probe/report.json \
  --baseline probe/decimal/baseline.json
```

The schema-v5 baseline contains 42 blockers across four modules and 243
source definitions. All four module attempts remain blocked by module forms;
the `Decimal.Error` diagnostic shadow reaches lowering completion and the
`Decimal.Macros` shadow remains synthetic-only.

The 24 `module_level_generation` blockers retain their original reason and
stable identity while gaining structural evidence. Six forms contain
definition generation: three `if/2` roots, one match whose subtree generates
functions, and two default-argument `def/1` forms rejected before default-arg
expansion. The remaining 18 forms are top-level `doc_since/1` calls. Blocker
IDs, module attempts, and diagnostic attempts are unchanged.

This distribution does not provide a narrow Decimal lowering slice. The
definition-generating forms require compile-time expansion, and the repeated
`doc_since/1` calls depend on imported macro semantics. The next step is a
Batata-owned probe for bounded, literal `for`/`if` definition generation,
shared with the Jason frontier. A lowering implementation starts only if that
probe advances at least one diagnostic or module attempt; a smaller raw
blocker count is not sufficient. No Beaver runtime change is indicated by
this compile-time evidence.
