# Jason compile probe

Jason is an external semantic conformance corpus for Batata. It is not a JSON
implementation or production dependency of Batata or Beaver.

The probe has two deliberately separate surfaces:

- `mix batata.jason_probe` inventories unmodified Jason source at the current
  parse/frontend boundary. It collects every blocker instead of stopping at
  the first unsupported form.
- Structurally eligible modules also enter a non-executing compile-attempt
  lane. The lane preserves the frontend-normalized forms from the original
  target-module body in order, excludes sibling modules and file-level forms,
  and appends a synthetic non-executing `main/0` only when one is missing. It
  records the first failing phase and never treats the result as per-definition
  coverage or an unmodified whole-file compile.
- The `dependency_frontier` records remote calls made by those eligible
  modules and distinguishes calls into the pinned corpus from external calls.
  It is measurement only; targets are not resolved or compiled together.
- `test/probe/jason/semantic_kernels_test.exs` executes minimized,
  Batata-owned kernels shaped like Jason's token, number, UTF-8, and escape
  scanners and compares their results with the BEAM implementation.
- `test/probe/jason/decoder_subset_test.exs` executes a selected scalar JSON
  decoder surface. Valid and invalid tokens exercise guarded byte/rest and
  UTF-8 scanner paths against a BEAM oracle; a representative number token
  also runs through the AOT gate.

## Pinned corpus

[`source.json`](source.json) pins Jason `v1.4.5` to an exact commit. CI checks
out that commit explicitly; the probe does not rely on Jason being present as
a transitive Kinda or development dependency.

To reproduce the inventory locally:

```sh
git clone https://github.com/michalmuskala/jason.git /tmp/batata-jason
git -C /tmp/batata-jason checkout 4ede42858eb19f80ec9e863aab52df466eab8608
mix batata.jason_probe \
  --source /tmp/batata-jason \
  --output _build/jason_probe/report.json \
  --baseline probe/jason/baseline.json \
  --fail-on-regression
```

The checked-in baseline is a golden report, not a target number. A blocker
disappearing is progress; a newly accepted form must still be tested through
IR verification, lowering, execution, and a BEAM oracle before it counts as
semantic support. Compiler crashes, verifier failures, and runtime mismatches
must never be converted into expected frontend blockers.
Modules blocked by top-level forms remain visible as
`blocked_by_module_forms`; a previously passing module compile attempt becoming
a compile or lowering failure is a probe regression.
Diagnostic-attempt changes are reported separately by module and path. Changes
to their outcome, error, phase, or reason class expose movement in the shadow
compile frontier; fingerprint-only drift remains visible but informational.
Diagnostic-only changes do not affect the blocker or compile-attempt regression
gate.

Schema v6 retains the v5 structural classification and adds an explicitly
diagnostic-only `generation_attempts` lane. It accepts only one bounded shape:
a single generator over a non-empty literal list whose body contains only
`def`/`defp` forms and substitutes the generator through `unquote/1`. Ranges,
filters, multiple generators, bare generator references, nested `fn`/`quote`,
macro or protocol definitions, and compile-time remote evaluation are rejected.
The attempt compiles an isolated synthetic module and reports all excluded
module scope; it does not change blocker identity, module eligibility, or the
regression gate.

Pinned Jason has exactly one accepted candidate: the literal-list `for` at
`lib/encode.ex:233`. It expands the Date, Time, NaiveDateTime, and DateTime
clauses and now dispatches their compile-known atom literals. Batata's
`Date.to_iso8601/1` replacement executes the full supported Date range against
a BEAM oracle. Its `Time.to_iso8601/1`, `NaiveDateTime.to_iso8601/1`, and the
UTC-only `DateTime.to_iso8601/1` replacement likewise execute closed
packed-integer slices across all microsecond display precisions, including the
generated clauses' iodata-shaped body. The DateTime slice accepts only the
literal `Etc/UTC` zone and emits the `Z` suffix. None of these replacements
accepts host Date, Time, NaiveDateTime, or DateTime structs. The whole-corpus
link now crosses all four generated encoders. Nested module aliases reach the
same stdlib boundary as single-part aliases. The list implementation of the
Enumerable protocol now lowers to compiler-owned helper clauses which preserve
`:cont`, `:halt`, `:suspend`, completion, and resumable-continuation results
while invoking reducers through the term-word closure ABI. This makes
`Enumerable.Jason.OrderedObject` an isolated compile pass and advances the
whole-corpus requirement to the direct `String.Chars.to_string/1` callback
contract. That callback now shares the bounded `Kernel.to_string/1` scalar
lowering for integers, binaries, and compile-known atoms, including the same
typed failure for unsupported values. The whole-corpus frontier consequently
reached the generated `Jason.Formatter.tab/2` clauses. Multi-clause dispatch
now admits compile-known integer literals in trailing positions, uses the term
ABI for those arguments without changing binary-scanner signatures, and
matches compile-known binary literals by length and bytes. This crosses all 16
generated indentation clauses. Bounded metaprogramming evaluation now folds
the compile-known `String.duplicate/2` calls in those clauses, with a 512-byte
generation limit; ordinary compile-known calls use the same non-negative
argument contract and reject results larger than 1 MiB before allocation.
Dynamic string repetition remains unsupported. Positive-count runtime
`List.duplicate/2` now lowers to a compiler-owned `scf.while` which accepts any
term, allocates one cons cell per iteration, and stops immediately when the
bounded arena reports allocation failure. It is deliberately non-resumable:
the current single continuation slot is not safe across nested or repeated
call sites. Count zero also fails closed until the Ex ABI distinguishes `[]`
from the nil atom. These architecture gaps are tracked separately in Beaver
issues #98 and #97. This crosses the Formatter fallback and advances the
whole-corpus frontier to `Jason.Decoder.escapeu_last/3`. Batata now computes a
conservative fixed point for local helpers whose every clause ends in a direct
`throw/1` or another proven no-return helper. A trailing case branch which
calls such a helper is typed from the already-established live branches; this
crosses the generated Unicode fallback without accepting ordinary mixed
scalar/term cases or inferring through `try/catch`, conditionals, or external
calls. The frontier consequently advances to the Formatter clauses whose
trailing `opts` argument uses the literal map pattern `%{pretty: true} = opts`.
This lane still makes no execution claim for module-level generation; the
reducer, protocol-callback, literal-dispatch, bounded string-fold, positive
list-duplication, and no-return case evidence comes from compiler-owned
lowering and execution gates.

The atom-keyed map gates cover case-clause subset matching and function
parameter destructuring, including present-nil versus missing keys and
non-map fall-through. Non-exhaustive cases and function dispatch now use a
typed exception path: `CaseClauseError` and `FunctionClauseError` bypass user
`catch` frames while retaining their reason through the host result handle.
Canonical frontend normalization now admits current-module `defexception`
schemas to the compile-attempt lane. The original target-module bodies for
`Jason.DecodeError` and `Jason.EncodeError` reach lowering completion. It also
admits canonical current-module `defstruct` schemas: this removes the schema
blockers from `Jason.Fragment` and `Jason.OrderedObject`, although only the
latter becomes compile-eligible. This is `struct.schema_compile` and
`exception.schema_compile` evidence only: it does not claim execution support
for `raise`, `rescue`, or `Exception.message/1` dispatch. `@behaviour` is
ignored as compile metadata, which moved the pinned Jason inventory from 73 to
72 blockers and from 76 to 77 ignored metadata entries before the exception
schema blockers were resolved.

Arity-carrying module-local closures now give `is_function/1,2` an executable
JIT gate while preserving the legacy closure layout. Probe eligibility remains
separate from compiler acceptance and requires canonical guarded-definition
evidence. This resolves the guarded forms in `Jason.Decoder` and
`Jason.Fragment`, moving the pinned baseline from 68 to 66 blockers and from
239 to 241 accepted source definitions. `Jason.Decoder` remains blocked by
other module forms. `Jason.Fragment` now becomes the third target-module-body
compile pass; this is non-executing compile evidence and does not claim that a
host-supplied encoder closure can cross the runtime boundary.

Schema v6 also records a diagnostic-only `closure_frontier`. It classifies
dynamic applications by the callable expression visible in each original
definition: module-local closure syntax, caller parameters, direct
cross-module captures, or other external expressions. The same canonical
classification is attached to a compile-attempt failure when the module has
no local closure dispatch. In the pinned corpus, `Jason.OrderedObject` still
fails with `dynamic_apply_without_local_dispatch`; its two sites consume
caller-supplied functions. This is static provenance evidence, not a compile
pass or an execution claim for captures created by another Jason module.

String interpolation now executes for integer, binary, and compile-known atom
terms. Binary reads execute for valid binaries with in-range integer indexes;
binary concatenation executes for binary operands and fails closed outside
that domain. Body-level short-circuit `&&` now preserves Elixir's original
operand values, treats only `false` and `nil` as falsy, and keeps the right-hand
side lazy; assignments in that right-hand side remain outside the supported
environment model. Body-level `if` follows the same truthiness rules, keeps
unselected branches lazy, returns `nil` when `else` is omitted, and deliberately
excludes assignments inside branches until branch-local SSA environments are
modeled. `String.printable?/1` now has an executable runtime and
BEAM-oracle gate, and bounded `Kernel.inspect/1,2` now covers the integer,
binary, compile-known atom, nil, and boolean terms used by its error messages.
The original `Jason.DecodeError`, `Jason.EncodeError`, and `Decimal.Error`
target-module bodies now reach lowering completion in compile attempts.
Current-module struct constructors and patterns have
executable BEAM-oracle gates covering declared defaults, validated overrides,
exact `__struct__` matching, field validation, aliases, and nested atom-key map
patterns. Generic exact map updates cover literal atom keys, left-to-right BEAM
evaluation order, immutable replacement, `KeyError`, and `BadMapError`.
`Jason.OrderedObject` enters the real module compile-attempt lane with its
schema preserved.
Clause-local trailing argument names now let its recursive `delete_key/2`
clauses pass frontend dispatch validation, including the repeated-key equality
between the first pattern and trailing argument. Native, resumable
`:lists.keyfind/3` and `:lists.reverse/1,2` now execute with BEAM-oracle gates,
including loose numeric key equality and invalid-argument paths. The attempt
crosses those calls, guarded `new/1`, and the duplicate symbols previously
emitted for `get_and_update/3,4`. It fails closed at frontend normalization
because dynamic `fun.(current)` application has no
module-local anonymous function from which Batata could build `__fn_dispatch`.
Modules that pass locally-created closures through helper parameters retain
their executable dispatch path. The host and AOT ABIs do not promise support
for externally supplied closure terms. `Jason.OrderedObject` is therefore not
a module pass. `Jason.Fragment` passing does not change that conclusion:
`OrderedObject` still applies a closure whose provenance is external to its
target module. Cross-module schemas, external closure provenance, and complete
exception semantics remain outside the claim.

The next measured struct frontier is therefore no longer constructor, pattern,
or generic map-update syntax. Decimal's full modules remain blocked earlier by
compile-time forms and unavailable cross-module schemas, while Jason's full
modules remain dominated by macro, attribute, generation, and protocol
surfaces. Those blockers must be measured independently of schema eligibility.

`capabilities.json` is the semantic scorecard. Unlike raw accepted-definition
counts, every `executable` row names an end-to-end gate; `shaped` rows name a
scanner/IR probe; and every `blocked` row has one owning layer and a reason.
JSONTestSuite is pinned separately under `probe/json_test_suite/source.json`
because it supplies data, not Elixir implementation source.

The matrix also records the first blockers exposed by replacing whole-input
literal clauses with a cursor parser. A dynamic `{value, rest}` call result is
owned by `lift`; incremental map and escaped-binary construction remain
lowering/runtime primitive gaps. Keeping these rows separate prevents the
existing compile-time `ex.map` and `ex.binary` constructors from being counted
as runtime parser support.

A second implementation fixture is admitted only after its minimized kernel
inventory has no runtime-owned blockers and every accepted semantic surface
has a BEAM oracle plus JIT gate. Full libraries whose first blockers are macro,
attribute, behaviour or protocol expansion remain frontend work rather than
runtime evidence.

## Stages and roadmap

The report reserves stages from parse through runtime mismatch so later probes
can extend the same schema. The current unmodified-source pass primarily
classifies macro/compile-time, frontend, guard/pattern, and protocol blockers.

The implementation sequence tracked by Beaver Forgejo issue #63 is:

1. source inventory and stable blocker report;
2. decoder-shaped executable kernels;
3. a selected decoder subset with valid/invalid JSON corpus;
4. encoder, iodata, and protocol dispatch.

The runtime switch gate is complete: Beaver Forgejo #60–#62 supplied the
lifecycle race harness, replayable actor/runtime soak, and TSan/cross-runtime
coverage. Those jobs remain mandatory regression gates while Jason drives
semantic width. This decoder subset is deliberately below “unmodified Jason
compiles”: macro expansion, module attributes, protocol dispatch, full JSON
container construction, exceptions, and encoder/iodata remain explicit later
milestones.
