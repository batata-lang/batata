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

The schema-v6 baseline inventories four modules, 245 source definitions, and
37 blockers.
Canonical frontend normalization admits the current-module `defexception`
schema in `Decimal.Error`, so its original target-module body reaches lowering
completion in the non-executing compile-attempt lane. The lane excludes sibling
and file-level forms and appends a synthetic non-executing `main/0` only when
missing. This is schema compilation evidence, not an unmodified whole-file
compile or execution support for `raise`, `rescue`, or `Exception.message/1`.
The same canonical evidence removes the current-module `defstruct` blockers
from `Decimal` and `Decimal.Context`. Arity-carrying module-local closures and
the executable `is_function/1,2` gate additionally resolve `Decimal.Context`'s
`with/2` and `update/1` guarded-definition blockers. Both modules still remain
blocked by imports, attributes, module-level generation, and other guards;
neither enters a compile attempt, and the dependency frontier remains at two
eligible calls.
`Decimal.Macros` remains diagnostic-only and synthetic-only.

The 24 `module_level_generation` blockers retain their original reason and
stable identity while gaining structural evidence. Six forms contain
definition generation: three `if/2` roots, one match whose subtree generates
functions, and two default-argument `def/1` forms rejected before default-arg
expansion. The remaining 18 forms are top-level `doc_since/1` calls. Blocker
IDs, module attempts, and diagnostic attempts are unchanged.

The shared diagnostic generation lane accepts one of those forms: the exact
`Version.compare(System.version(), "1.3.0") == :lt` gate at
`lib/decimal.ex:2080`. It validates both `defp` branches without evaluating
arbitrary source, selects the branch for the running Elixir toolchain, and
submits that single definition to Batata in an isolated synthetic module. On
the recorded Elixir 1.20.3 / OTP 29 toolchain, the selected branch calls
`Integer.to_charlist/1`. Batata's bounded production lowering for that call
lets the isolated definition reach `lowering_complete`, with no subsequent
compile blocker.

This remains diagnostic-only evidence, not production Decimal semantics or
per-definition coverage. The other definition-generating forms still require
different compile-time expansion, and the repeated `doc_since/1` calls depend
on imported macro semantics. No blocker, module attempt, or existing diagnostic
attempt changes, and this compile-time frontier does not claim broader Decimal
runtime semantics.
