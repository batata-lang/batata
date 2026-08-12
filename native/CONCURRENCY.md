# Runtime lock order and sanitizer matrix

`term_runtime.zig` uses generation-checked global registries to locate an
object, but long graph traversal and allocation are scoped to one runtime.
The registry locks must never become a global execution gate.

## Lock order

When locks overlap, acquire them in this order:

1. runtime registry (`runtime_lock`)
2. per-runtime lifecycle gate (`Runtime.lifecycle_lock`)
3. per-runtime heap (`heap_lock`)
4. result or term registry (`result_lock` / `term_lock`)
5. exported registry (`exported_lock`) as a leaf lock

The result and term registries are peers; no path may hold one while acquiring
the other. The exported registry is not held while validating, encoding,
decoding, allocating, or acquiring a runtime gate. Import instead retains the
immutable byte slice, releases `exported_lock`, and drops the retain after the
runtime operation. Scheduler delivery follows its separate order of
`scheduler_lock -> mailbox lock -> process state_lock`.

Bound execution calls use the thread-local runtime pointer and do not look the
runtime up again. Unbound handles use a two-phase operation: snapshot the
handle under its registry lock, release it, then reacquire
`runtime_lock -> lifecycle_lock -> handle registry` and revalidate generation,
runtime pointer, and runtime handle before committing.

## Public multi-lock paths

| ABI path | Acquisition path |
| --- | --- |
| `runtime_enter`, `runtime_destroy` | runtime registry -> lifecycle |
| `result_destroy` | result snapshot; release; runtime registry -> lifecycle -> result revalidation |
| `handle_destroy` | term snapshot; release; runtime registry -> lifecycle -> term revalidation |
| `export(result, word)` | result snapshot; release; runtime registry -> lifecycle -> result revalidation; release all; graph traversal/allocation; exported leaf |
| `handle_export` | term snapshot; release; runtime registry -> lifecycle -> term revalidation; release all; graph traversal/allocation; exported leaf |
| `import` | exported retain/release; lifecycle -> heap allocation; lifecycle -> term publication |
| `result_create` | bound lifecycle -> result publication |
| `process_table_reset` | bound lifecycle -> heap/scheduler initialization |
| `exported_clone/length/get/destroy` | exported leaf only |

All busy paths inspect state under the lifecycle gate and return immediately;
they do not spin waiting for another lifecycle phase. The only spin barriers
in the native test build are deterministic test hooks and are compiled out of
production artifacts.

## TSan and semantic matrix

`scripts/tsan.sh` runs the complete native suite, so TSan observes both the
race cases and their busy/stale semantic assertions. The principal cases are:

| Required interaction | Native case |
| --- | --- |
| leave / export-begin | `leave to idle linearizes before result export begins` |
| enter / result export / destroy | `result export lease excludes enter and destroy until the copy completes` |
| runtime destroy / result export | the result-export lease case above |
| runtime destroy / term export | `term export lease survives handle destroy and excludes runtime destroy` |
| result destroy / export | `result destroy revalidates after a concurrent export` |
| term destroy / export | `term destroy revalidates after a concurrent export` |
| import / leave / runtime destroy | `import publishes its term pin before leave and destroy can proceed` |
| term pin / reset | `term pins block reset until released and export leases protect snapshots` |
| exported clone / inspect / destroy | `exported clone inspection and destroy serialize without stale reads` |
| worker join / owner leave / cleanup | `runtime lifecycle admits one owner and tracks joined workers` |
| stale worker and registry generations | `worker tokens reject stale foreign and repeated lifecycle operations` and portable-handle stale cases |
| arena segment acquire and allocation | `workers reserve independent bump segments` and the native actor/arena soak cases |
| cross-runtime result export progress | `independent runtime progresses while result graph export is paused` |
| cross-runtime term export progress | `independent runtime progresses while term handle export is paused` |
| cross-runtime import progress | `independent runtime progresses while graph import owns another runtime gate` |

The three cross-runtime cases use barriers, not elapsed-time thresholds. Runtime
A is paused at a graph phase while runtime B must create, enter, reset, export,
inspect, and destroy an independent execution before A is released.
