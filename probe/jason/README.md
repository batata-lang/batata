# Jason compile probe

Jason is an external semantic conformance corpus for Batata. It is not a JSON
implementation or production dependency of Batata or Beaver.

The probe has two deliberately separate surfaces:

- `mix batata.jason_probe` inventories unmodified Jason source at the current
  parse/frontend boundary. It collects every blocker instead of stopping at
  the first unsupported form.
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

`capabilities.json` is the semantic scorecard. Unlike raw accepted-definition
counts, every `executable` row names an end-to-end gate; `shaped` rows name a
scanner/IR probe; and every `blocked` row has one owning layer and a reason.
JSONTestSuite is pinned separately under `probe/json_test_suite/source.json`
because it supplies data, not Elixir implementation source.

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
