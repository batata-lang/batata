# Batata Decimal

`batata_decimal` owns Decimal as an independent external compile-coverage
corpus for Batata. It is not a production dependency of the compiler, and the
inventory does not claim that an accepted definition executes with Decimal
semantics.

[`source.json`](priv/probe/source.json) pins Decimal `v2.3.0` to commit
`592d59ac4474933f91cdc3e8e037f137f7e008b0`. To reproduce the report:

```sh
git clone https://github.com/ericmj/decimal.git /tmp/batata-decimal
git -C /tmp/batata-decimal checkout 592d59ac4474933f91cdc3e8e037f137f7e008b0
cd packages/batata_decimal
BATATA_PATH=../.. BATATA_PROBE_PATH=../batata_probe mix batata.decimal.probe \
  --source /tmp/batata-decimal \
  --report _build/decimal_probe/report.json \
  --coverage _build/decimal_probe/coverage.json \
  --fail-on-regression
```

The schema-v6 baseline inventories four modules, 245 source definitions, and
37 blockers.
The qualified whole-unit compile/link attempt now lowers Decimal's
`Process.put/2` use and `Decimal.Context.get/0` through actor-local process
dictionary intrinsics. It also lowers all positive and negative
`List.insert_at/3` calls in Decimal's normal/scientific formatting paths.
Exact-once `try/after` cleanup now preserves normal and handled results,
restores unmatched throw/raise kind and reason after cleanup, and lets cleanup
failures replace a pending result or unwind. Fixed-size byte-aligned binary
patterns now reuse the existing `ex.binary_part` ABI and advance their match
offset without broadening support to dynamic or bit-level sizes. This crosses
`remainder::size(7)-binary` in `Decimal.parse_unsign/1`; the next qualified
whole-unit path now uses a bounded ASCII `String.downcase/1` replacement. It
maps ASCII uppercase bytes and explicitly rejects non-ASCII input rather than
approximating Unicode casing. This crosses all three Infinity/NaN comparisons;
strict charlist integer conversion now accepts optional signs, normalizes
leading zeros, and constructs immediate or boxed arbitrary-precision integers
without expanding the runtime ABI. This crosses Decimal's
`List.to_integer/1` and `:erlang.list_to_integer/1` calls. The next fail-closed
path packs Decimal's 1/11/52 integer fields into one big-endian binary64 word
and matches its default `tmp::float` segment through existing scalar and term
operations. Non-finite bit patterns fail to match as they do on BEAM, and no
runtime ABI is added. This crosses `Decimal.to_float/1`. Lazy strict `or`
lowering and recursive `and`/`or` boolean proof then cross the nested atom
comparisons in Decimal's threshold `compare/3` without accepting general term
truthiness. Exact empty-list (`[]`) trailing arguments in multi-clause functions
then reuse the existing structural `list_exact(0)` matcher, preserving clause
order and fallback behavior without adding an ABI. Structural cons tail
patterns then reuse the existing nonempty/head/tail matcher; their clause-local
bindings retain term validation before integer ordering, so Decimal's rounding
digit comparisons advance without assuming arbitrary list elements are
integers. Signature inference now retains the boolean-result contract of the
validated internal `:lists.any/2` node, including through compilation-unit
qualification and private local forwarding. This crosses the rewritten
`any_nonzero(remain)` call under strict `and` without trusting unknown or mixed
local calls. Resumable `:lists.last/1` traversal then preserves its final term
and FunctionClauseError boundary across reduction yields. Scalar-call cleanup
folds stale term adapters, exact integer comparisons retain their term result,
and Beaver expands integer case patterns over term scrutinees with strict term
equality. Together these changes move the whole-unit attempt through IR
verification into standard lowering. Schema-aware static exception
normalization now resolves aliased and fully-qualified application `raise/2`
calls only after compilation-unit `defexception` schemas are shared. Runtime
keyword attributes are validated against the schema and materialized as the
existing term-valued exception representation; unknown schemas and local
`raise/2` definitions remain fail-closed. This crosses Decimal's
`raise Error, error` path. Dynamic unary integer negation and identity now
reuse the scalar arithmetic proof boundary, with explicit rejection of the
minimum i64 negation instead of silent wrapping. This crosses Decimal's
dynamic `-sign` path. The next fail-closed frontier is an unresolved list
concatenation `++/2` call in standard lowering (`de7771...3b12`). Resumable
list concatenation now copies and validates the proper left spine before
reversing it onto an arbitrary right tail. It preserves empty-left and
improper-result semantics while deferring the second allocation pass until a
budgeted traversal completes. This crosses Decimal's charlist formatting
concatenations; the next standard-lowering frontier is the unresolved internal
`canonical_xsd/1` call (`d8d65c...47beb`). Private reachability now expands
nested pipelines before collecting references, so the effective arity used by
qualification is also used by pruning. This retains Decimal's private
`canonical_xsd/1` recursion without retaining its unrelated private functions.
The next frontier is the term-pattern guard
`Kernel.rem(coef, 10) != 0` (`9f3d37...c7e3`). The isolated
`Decimal` attempt still reports the cross-module `Decimal.Context.get/0` call
because that diagnostic lane omits sibling modules; it does not contradict the
whole-unit advance.
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

The shared schema-v6 `closure_frontier` additionally records the caller-
supplied functions applied by `Decimal.Context.with/2` and `update/1`. Because
the module remains blocked by its top-level forms, no structured closure field
is added to a module compile attempt and no execution capability is claimed.

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
