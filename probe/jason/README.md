# Jason compile probe

Jason is an external semantic conformance corpus for Batata. It is not a JSON
implementation or production dependency of Batata or Beaver.

The probe has two deliberately separate surfaces:

- `mix batata.jason_probe` inventories unmodified Jason source at the current
  parse/frontend boundary. It collects every blocker instead of stopping at
  the first unsupported form.
- Structurally eligible modules also enter a non-executing compile-attempt
  lane. The lane compiles and lowers a complete synthetic module, records the
  first failing phase, and never treats its result as per-definition coverage.
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

The atom-keyed map gates cover case-clause subset matching and function
parameter destructuring, including present-nil versus missing keys and
non-map fall-through. Non-exhaustive cases and function dispatch now use a
typed exception path: `CaseClauseError` and `FunctionClauseError` bypass user
`catch` frames while retaining their reason through the host result handle.
The diagnostic lane records the next blocker actually reached by
`Jason.DecodeError`, `Jason.EncodeError`, `Jason.OrderedObject`, and
`Decimal.Error`; it does not count that deeper diagnostic as a complete module
pass. `@behaviour` is ignored as compile metadata, which moves the pinned Jason
inventory from 73 to 72 blockers and from 76 to 77 ignored metadata entries.

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
The shadow `Jason.DecodeError`, `Jason.EncodeError`, and `Decimal.Error` reach
lowering completion. Current-module struct constructors and patterns have
executable BEAM-oracle gates covering declared defaults, validated overrides,
exact `__struct__` matching, field validation, aliases, and nested atom-key map
patterns. Generic exact map updates cover literal atom keys, left-to-right BEAM
evaluation order, immutable replacement, `KeyError`, and `BadMapError`.
`Jason.OrderedObject` enters the diagnostic lane with its schema preserved.
Clause-local trailing argument names now let its recursive `delete_key/2`
clauses pass frontend dispatch validation, including the repeated-key equality
between the first pattern and trailing argument. The shadow now exposes the
next precise blocker, unsupported `:lists.keyfind/3`; it is not a module pass.
`Jason.Fragment` retains its guarded-definition blocker and is deliberately not
stripped into a shadow attempt. Cross-module schemas and complete exception
semantics remain outside the claim, and module pass counts remain zero.

The next measured struct frontier is therefore no longer constructor, pattern,
or generic map-update syntax. Decimal's full modules remain blocked earlier by
compile-time forms and unavailable cross-module schemas, while Jason's full
modules remain dominated by macro, attribute, generation, and protocol
surfaces. Those blockers must be measured independently of the diagnostic
shadows.

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
