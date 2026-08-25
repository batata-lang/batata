# Zig term runtime ABI (declaration-first manifest)

This file is the source of truth for the `ex` term universe ABI. Beaver's
conversion plan (`Beaver.MLIR.Conversion.Ex`) emits calls to the symbols
listed here, and [`term_runtime.zig`](./term_runtime.zig) implements them.
The two sides must stay in lockstep; change the manifest first, then both
sides.

## Term representation

A term is a 64-bit **tagged word** (`i64`). The low 3 bits hold the tag; the
remaining 61 bits hold the payload.

| tag | value | meaning |
| --- | --- | --- |
| `int` | `0b000` | immediate integer: `value << 3` |
| `atom` | `0b001` | immediate atom: `id << 3 \| 1` |
| `tuple` | `0b010` | heap pointer to a tuple header |
| `list` | `0b011` | heap pointer to a cons cell |
| `map` | `0b100` | heap pointer to a map header |
| `binary` | `0b101` | heap pointer to a binary header |
| `fun` | `0b110` | heap pointer to a closure header |
| `runtime-local` | `0b111` | marked immediate PID/reference; never portable across runtime/session boundaries |

Heap objects are 8-byte aligned, so the low 3 bits of a container pointer are
always zero and the tag can be OR-ed in. `nil` is the atom with id 0
(`word == 1`); it doubles as the empty list, matching BEAM.

The heap, process table, callback registry, and scheduler counters belong to
an explicit `Runtime`; the exception stack remains worker-local. The current
compatibility entry lazily creates one runtime per OS thread, while the handle
API provides the lifecycle and binding boundary needed by a worker pool.
Independent Batata executions may therefore run concurrently on different
BEAM scheduler threads without sharing mutable runtime state.
`ex.term.process_table_reset` starts a fresh execution in the bound runtime
and reuses its arena allocation.

## Runtime lifecycle

An explicit runtime has a short-lock lifecycle gate and moves through
`idle`, `executing`, `exporting`, and `destroying`. `runtime_enter` is the
only public operation that creates an execution owner. A successful
`idle -> executing` transition increments a non-zero `u64` execution epoch;
same-handle re-entry is a no-op, and another thread cannot enter the same
execution. Epoch overflow rejects a new execution instead of wrapping.

The normative multi-lock acquisition order, public ABI acquisition paths, and
the sanitizer race matrix are documented in
[`CONCURRENCY.md`](./CONCURRENCY.md).

The owner counts as participant 1 and may run dispatcher work directly as
worker 1. Additional OS workers join internally with a thread-local token
bound to the runtime generation and execution epoch, and must leave on every
controlled exit path. Owner bindings and worker tokens are mutually
exclusive. The owner cannot leave until every joined worker has left.

The generated single- and multi-worker drivers call
`ex.term.process_table_reset` exactly once at execution start. For an
explicit runtime this is an owner-only transition from uninitialized to
initialized; a repeated reset returns `-1`. `result_create` is likewise an
owner-only operation after initialization and worker quiescence. Lifecycle
failures do not implicitly destroy the runtime or clear the owner binding.

This boundary does not yet make the actors inside one execution parallel: its
generated scheduler still dispatches them on one worker in round-robin order.
The runtime provides atomic actor claim/release, locked cross-worker mailbox
delivery, and a fixed worker pool that invokes actor entries through a stable
trampoline. The single-worker generated driver remains the default fallback.

Heap layouts (all fields are `i64` words):

```
tuple:  [len] [elem × len]
map:    [len] [entry × 2*len]   (flat key/value pairs; len = pair count)
binary: [len: i64] [packed byte: u8 × len] [alignment padding]
list:   cons cells [head] [tail]
fun:    [fn_idx] [env_len] [env × env_len]
```

## Portable exported values

`ex.term.export` copies a quiescent result-owned graph into an immutable,
versioned `BTA\x01` encoding capped at 16 MiB and 256 levels of nesting. The
encoding contains no arena addresses. `ex.term.import` validates the complete
encoding and computes its exact arena requirement before reserving one block,
so malformed input and allocation failure cannot expose a partial graph.

The first version supports scalar roots, tagged integers/atoms, tuples,
proper or improper lists, maps, and packed inline binaries. Closures are
rejected. Atom payloads are portable only between sessions using the same
compiled artifact/atom identity scheme; this is not a distributed wire
format. Runtime-local PID/reference/resource representations are outside this
ABI and must not be introduced into the supported tag set without an explicit
codec kind and import policy.

An imported value is represented to the host only by a term handle bound to
the target runtime generation. Destroying the handle releases its lease, not
the arena object. The target runtime cannot be destroyed while such a lease
exists. Persistent regions, refcounted large binaries, and sub-binaries are
separate follow-up work.

Result and term handles are arena pins. Any outstanding pin rejects a new
execution/reset. A result is the final runtime owner: `result_destroy` returns
`-2` without changing either handle when term pins remain, and succeeds after
those term handles are destroyed. Releasing the last term pin never destroys
the runtime implicitly.

Export uses an exclusive per-runtime lease. Handle generation/ownership
revalidation, root snapshot, and `idle -> exporting` commit atomically under
the runtime gate; encoding happens after the registry locks are released.
Runtime/result destruction is busy until encoding releases the lease. A term
handle may be destroyed after the export commit because the lease itself
keeps the arena alive. Successfully exported bytes are independently owned by
the exported registry and survive destruction of every source object.

Import first retains an immutable exported encoding without holding its
registry lock across validation or allocation. It then validates the owner
execution is quiescent and publishes the graph and term pin under the runtime
gate. Import before process initialization is a supported storage-only path;
its pin blocks reset until the term handle is destroyed.

## Intrinsics

All functions use the C ABI and return/accept `i64` tagged words unless noted.

| symbol | signature | semantics |
| --- | --- | --- |
| `ex.term.runtime_create` | `() -> i64` | allocate an isolated runtime and return a generation-checked opaque handle; 0 when the bounded registry is full |
| `ex.term.runtime_set_arena_limit` | `(handle: i64, bytes: i64) -> i64` | configure the idle runtime quota; 0 success, -1 stale, -2 active/pinned, -3 invalid or above the 64 MiB hard limit |
| `ex.term.runtime_enter` | `(handle: i64) -> i64` | become the sole owner of an idle runtime; same-handle owner re-entry is a no-op; -1 stale, -2 busy/foreign binding/epoch exhausted |
| `ex.term.runtime_leave` | `() -> i64` | return an owned execution to idle; -1 when unbound/not owner, -2 while joined workers remain |
| `ex.term.runtime_destroy` | `(handle: i64) -> i64` | destroy an idle runtime with no result/term leases; -1 stale/foreign, -2 busy |
| `ex.term.runtime_arena_bytes` | `(handle: i64) -> i64` | arena capacity currently reserved in bytes |
| `ex.term.runtime_arena_chunks` | `(handle: i64) -> i64` | number of stable arena segments |
| `ex.term.runtime_arena_high_water` | `(handle: i64) -> i64` | high-water allocation in bytes for the current execution |
| `ex.term.runtime_arena_limit` | `(handle: i64) -> i64` | effective per-execution arena quota in bytes |
| `ex.term.runtime_oom` | `(handle: i64) -> i64` | 1 after any arena allocation failure in the current execution |
| `ex.term.result_create` | `(runtime: i64, word: i64) -> i64` | owner-only retention of the sole initialized, quiescent execution result; 0 registry full, -1 unbound/not ready/foreign, -2 OOM, -3 duplicate ownership; failures preserve the runtime |
| `ex.term.result_destroy` | `(handle: i64) -> i64` | atomically release a live result pin and its runtime; -1 stale, -2 during execution/export or while another term pin remains; busy is side-effect free |
| `ex.term.result_arena_capacity_bytes` | `(handle: i64) -> i64` | retained runtime arena capacity in bytes, or -1 for a stale result |
| `ex.term.result_arena_chunks` | `(handle: i64) -> i64` | retained runtime arena segment count, or -1 for a stale result |
| `ex.term.result_arena_high_water` | `(handle: i64) -> i64` | retained execution allocation high-water in bytes, or -1 for a stale result |
| `ex.term.result_arena_limit` | `(handle: i64) -> i64` | retained execution quota in bytes, or -1 for a stale result |
| `ex.term.result_oom` | `(handle: i64) -> i64` | 1 when the retained execution observed OOM, 0 otherwise, or -1 for a stale result |
| `ex.term.result_root_kind` | `(handle: i64) -> i64` | return a heap-backed root's tag, 0 for a scalar root, or -1 for stale/runtime-local values |
| `ex.term.result_root_word` | `(handle: i64) -> i64` | return the retained root word, or -1 for a stale handle |
| `ex.term.result_exception_kind` | `(handle: i64) -> i64` | return the retained entry actor's exception discriminator, zero for no exception |
| `ex.term.result_exception_reason` | `(handle: i64) -> i64` | return the retained entry actor's exception reason word |
| `ex.term.result_term_kind` | `(handle: i64, word: i64) -> i64` | classify an immediate or a heap word owned by this result; -1 for stale/foreign words |
| `ex.term.result_atom_name` | `(handle: i64, word: i64) -> i64` | runtime-owned binary name for a dynamic atom; nil otherwise |
| `ex.term.result_term_length` | `(handle: i64, word: i64) -> i64` | container length under a live result, or -1 when invalid |
| `ex.term.result_term_get` | `(handle: i64, word: i64, index: i64) -> i64` | indexed tuple/list/map/binary access while the result is live; -1 when invalid |
| `ex.term.export` | `(result: i64, word: i64) -> i64` | deep-copy a result-owned graph under an exclusive export lease into independent host storage; 0 registry full, -1 stale/foreign, -2 OOM, -3 unsupported, -4 malformed/limit, -5 runtime not idle |
| `ex.term.import` | `(target_runtime: i64, exported: i64) -> i64` | owner-only import with no joined workers; immutable input is retained before allocation and graph/term pin publication is atomic; -1 stale, -2 OOM, -4 malformed/limit, -5 target not owned/quiescent |
| `ex.term.exported_clone` | `(exported: i64) -> i64` | retain an exported handle; -1 stale, -4 reference limit |
| `ex.term.exported_destroy` | `(exported: i64) -> i64` | release an exported handle and invalidate its generation after the last reference |
| `ex.term.exported_length` | `(exported: i64) -> i64` | portable encoding size, or -1 for stale handles |
| `ex.term.exported_get` | `(exported: i64, index: i64) -> i64` | read one portable encoding byte, or -1 for stale/out-of-range access |
| `ex.term.handle_export` | `(term_handle: i64) -> i64` | export an idle imported term under an exclusive runtime lease without exposing its arena word; -5 when runtime is not idle |
| `ex.term.handle_destroy` | `(term_handle: i64) -> i64` | atomically release a target-session arena pin; allowed during a committed export because the export lease protects the arena; -1 stale |
| `ex.term.list_cons` | `(head: i64, tail: i64) -> i64` | cons a word onto a list |
| `ex.term.self` | `() -> i64` | runtime-local pid of the current actor |
| `ex.term.send` | `(pid: i64, msg: i64) -> i64` | enqueue a message; returns the message, nil when the mailbox is full |
| `ex.term.receive` | `() -> i64` | dequeue the oldest message; nil when empty |
| `ex.term.mailbox_len` | `() -> i64` | number of messages in the current process's mailbox |
| `ex.term.mailbox_peek` | `(cursor: i64) -> i64` | message at `cursor` (0-based from the head) without removing it; nil when out of range |
| `ex.term.mailbox_remove` | `(cursor: i64) -> i64` | remove the message at `cursor`, shifting later messages forward |
| `ex.term.nil` | `() -> i64` | the nil term word (atom id 0) |
| `ex.term.monotonic_time` | `() -> i64` | wall-clock milliseconds (monotonic) for `receive ... after` timeouts |
| `ex.term.native_time` | `() -> i64` | BEAM native time unit (nanoseconds) for `erlang.monotonic_time/0,1` |
| `ex.term.unique_integer` | `(negative: i64) -> i64` | fresh logical-clock value for `erlang.unique_integer/0,1`; `negative` selects the decreasing series |
| `ex.term.receive_start` | `() -> i64` | the current process's `receive ... after` timeout start (0 = not started) |
| `ex.term.receive_start_set` | `(value: i64) -> i64` | set the current process's `receive ... after` timeout start |
| `ex.term.mailbox_clear` | `() -> i64` | reset the mailbox; the compiled entry calls this at startup |
| `ex.term.spawn` | `(fun: i64) -> i64` | create a new process with its own mailbox/clock and the given closure entry; returns a runtime-local pid with a BEAM-style generation serial, or nil on allocation failure. Completed slots are recycled with a bumped generation and the table grows beyond its initial capacity |
| `ex.term.process_table_reset` | `(cap: i64) -> i64` | owner-only one-shot initialization of an explicit execution; returns 1, nil when capacity is outside 1..4096, or -1 for worker/repeated/busy reset; compatibility runtimes retain legacy repeatable reset |
| `ex.term.cont_save` | `(arg: i64, acc: i64, cursor: i64) -> i64` | save the current process's cursor-loop continuation at the current epoch |
| `ex.term.cont_pending` | `() -> i64` | 1 when a continuation is saved at the current epoch (a stale epoch reads 0, so the entry restarts) |
| `ex.term.cont_active` | `() -> i64` | 1 when any continuation is saved (valid or stale); the entry's mailbox reset is gated on this so a resume keeps messages that arrived while suspended |
| `ex.term.cont_clear` | `() -> i64` | clear the saved continuation |
| `ex.term.cont_load_arg` / `cont_load_acc` / `cont_load_cursor` | `() -> i64` | saved loop state; nil when none is pending |
| `ex.term.receive_cont_save` | `(arg: i64, acc: i64, cursor: i64) -> i64` | save a selective-receive scan continuation; a message arrival invalidates it (epoch bump), unlike a cursor-loop continuation |
| `ex.term.schedule_next` | `() -> i64` | round-robin to the next runnable process and return its pid |
| `ex.term.process_claim_next` | `(worker_id: i64) -> i64` | atomically claim one runnable actor for a non-zero worker id; nil when none is available |
| `ex.term.process_release` | `() -> i64` | release the current claimed actor after a yielded slice |
| `ex.term.process_wait` | `(cursor: i64) -> i64` | atomically park the current actor when no message exists beyond the completed scan cursor |
| `ex.term.worker_run` | `(worker_count: i64, dispatcher: fn(i64) -> i64) -> i64` | run claimed actors on a fixed OS-worker pool and return process 1's result |
| `ex.term.worker_count` | `() -> i64` | configured worker count from the most recent pool run |
| `ex.term.worker_max_active` | `() -> i64` | maximum actors simultaneously executing in the most recent pool run |
| `ex.term.worker_migrations` | `() -> i64` | actor slice migrations between workers in the most recent pool run |
| `ex.term.process_thread_id` | `(pid: i64) -> i64` | last OS thread ID that executed the actor |
| `ex.term.current_entry` | `() -> i64` | closure word of the current process's entry; 0 for the compiled entry process |
| `ex.term.process_done` | `(result: i64) -> i64` | mark the current process done and store its result |
| `ex.term.process_exit` | `(reason: i64) -> i64` | mark the current process abnormally exited, record its reason and release its worker owner |
| `ex.term.process_trap_exit` | `(enabled: i64) -> i64` | set the current process's trap-exit flag and return its previous 0/1 value |
| `ex.term.link` | `(pid: i64, exit_tag: i64, normal_tag: i64) -> i64` | create a symmetric process link; nil on stale pid or relation-capacity exhaustion |
| `ex.term.unlink` | `(pid: i64) -> i64` | remove both sides of a process link; returns 1 when the pid is live |
| `ex.term.exit` | `(pid: i64, reason: i64, exit_tag: i64, normal_tag: i64) -> i64` | send an exit signal without linking; trapping targets receive `{EXIT, from, reason}` |
| `ex.term.monitor` | `(pid: i64, down_tag: i64, process_tag: i64, normal_tag: i64) -> i64` | monitor a live process and return a fresh runtime-local reference |
| `ex.term.demonitor` | `(reference: i64) -> i64` | remove a monitor owned by the current process; returns 1 when found |
| `ex.term.processes_runnable` | `() -> i64` | number of runnable processes (the driver loops while > 0) |
| `ex.term.process_result` | `(pid: i64) -> i64` | result of a completed process; nil when unknown or still runnable |
| `ex.term.process_exit_reason` | `(pid: i64) -> i64` | abnormal exit reason; nil for live, normally completed, stale or unknown pids |
| `ex.term.process_exit_kind` | `(pid: i64) -> i64` | typed exception discriminator; zero for ordinary exits and throws |
| `ex.term.raise` | `(reason: i64, kind: i64) -> noreturn` | bypass user catch frames and unwind to the actor boundary |
| `ex.term.clock_init` | `(budget: i64) -> i64` | set the reduction budget and reset the used counter |
| `ex.term.clock_tick` | `(cost: i64) -> i64` | charge reductions; 1 when the budget is exhausted (yield), else 0 |
| `ex.term.clock_budget_left` | `() -> i64` | remaining budget clamped to >= 0; -1 when no budget is set |
| `ex.term.clock_epoch` | `() -> i64` | current continuation-generation counter |
| `ex.term.clock_bump_epoch` | `() -> i64` | bump the epoch (message arrival / scheduler round); returns the new value |
| `ex.term.yield_mark` | `() -> i64` | record one preemptive yield at a slice boundary; returns the yield count |
| `ex.term.yield_count` | `() -> i64` | number of preemptive yields so far |
| `ex.term.to_int` | `(word: i64) -> i64` | untag an integer term to its scalar value; 0 for non-integers |
| `ex.term.make_fun` | `(fn_idx: i64, env_len: i64, e0..e3: i64) -> i64` | closure word referencing `__fn_*` by index with up to four captured env words |
| `ex.term.make_fun_with_arity` | `(fn_idx: i64, arity: i64, env_len: i64, e0..e3: i64) -> i64` | arity-carrying closure word referencing `__fn_*`; legacy closures remain readable |
| `ex.term.fun_idx` | `(fun: i64) -> i64` | function index of a closure; 0 for non-functions |
| `ex.term.fun_arity` | `(fun: i64) -> i64` | declared closure arity; -1 for non-functions and legacy closures |
| `ex.term.fun_env` | `(fun: i64, index: i64) -> i64` | captured env word at index; nil for non-functions / out-of-range |
| `ex.term.tuple_from_list` | `(list: i64) -> i64` | proper list -> tuple |
| `ex.term.tuple_get` | `(tuple: i64, index: i64) -> i64` | element at index; nil when out of range or not a tuple |
| `ex.term.tuple_length` | `(tuple: i64) -> i64` | tuple arity; 0 for non-tuples |
| `ex.term.map_length` | `(map: i64) -> i64` | map pair count; 0 for non-maps |
| `ex.term.enumerable_count` | `(word: i64) -> i64` | element count by tag: list length / tuple arity / map pairs / binary bytes; 0 otherwise |
| `ex.term.enumerable_to_list` | `(word: i64) -> i64` | materialize by tag: list identity, tuple elements, map `{k, v}` pairs, binary byte terms; nil for unsupported tags |
| `ex.term.enumerable_intersperse` | `(enumerable: i64, separator: i64) -> i64` | materialize and insert separator terms between adjacent elements; nil for unsupported tags |
| `ex.term.enumerable_into_map` | `(enumerable: i64, target: i64) -> i64` | merge list/map `{key, value}` pairs into a map in enumeration order; nil for malformed/unsupported inputs |
| `ex.term.enumerable_to_list_range` | `(start: i64, stop: i64) -> i64` | materialize an inclusive integer range as a list |
| `ex.term.enumerable_reduce` | `(enumerable: i64, acc: i64, continuation: i64) -> i64` | tag-dispatched reduce over list/tuple/binary/map; continuation 1 = sum, 2 = return acc, 3 = map values sum, 4 = map keys sum, 5 = map entries sum, 6 = product, 7 = acc - item, 8 = item - acc, 9 = div(acc, item), 10 = div(item, acc), 11 = rem(acc, item), 12 = rem(item, acc); zero divisor yields 0 |
| `ex.term.enumerable_reduce_c` | `(enumerable: i64, acc: i64, continuation: i64, capture: i64) -> i64` | closure-shaped reduce with a captured scalar; continuation 13 = sum with capture (acc + item + capture), 14 = product with capture (acc + item * capture) |
| `ex.term.enumerable_reduce_range` | `(start: i64, stop: i64, acc: i64, continuation: i64) -> i64` | inclusive integer range reduce (ascending or descending), reusing the continuation table (15 = count, acc + 1 per item) |
| `ex.term.enumerable_reduce_fun` | `(enumerable: i64, acc: i64, reducer_addr: i64) -> i64` | reduce by calling a compiled reducer `(item, acc) -> acc` on each item (list/tuple/binary); items are untagged integers |
| `ex.term.enumerable_map_fun` | `(enumerable: i64, mapper_addr: i64) -> i64` | map by calling a compiled mapper `(item) -> i64` on each item, producing a list in order |
| `ex.term.enumerable_map_term_fun` | `(enumerable: i64, mapper_addr: i64) -> i64` | map by calling a compiled term mapper `(tagged_item) -> tagged_result`, producing a list in order |
| `ex.term.enumerable_flat_map_term_fun` | `(enumerable: i64, mapper_addr: i64) -> i64` | flat-map by calling a compiled term mapper and concatenating each enumerable result in order |
| `ex.term.stream_filter` | `(list: i64, predicate_addr: i64) -> i64` | filter a list by a compiled predicate `(item) -> i64` (nonzero keeps), in order |
| `ex.term.stream_take` | `(list: i64, n: i64) -> i64` | first n elements (clamped to [0, len]) |
| `ex.term.stream_drop` | `(list: i64, n: i64) -> i64` | list without the first n elements (clamped to [0, len]) |
| `ex.term.register_callback` | `(fn_id: i64, callback: ptr) -> i64` | register a native callback entry (fn_id, function pointer); 0 on success, -1 out of range |
| `ex.term.call_callback` | `(fn_id: i64, arg: i64) -> i64` | call a registered native callback with an argument word; -1 when unregistered/out of range |
| `ex.term.jmp_buf_size` | `() -> i64` | byte size of libc `jmp_buf`, for stack allocation in compiled code |
| `ex.term.setjmp_addr` | `() -> i64` | address of libc `setjmp`, for indirect calls that avoid ORC symbol resolution |
| `ex.term.try_push` | `(buf: ptr) -> i64` | push a setjmp buffer for a try region; -1 when the 16-slot stack is full |
| `ex.term.try_pop` | `() -> i64` | pop the innermost try region's buffer |
| `ex.term.throw` | `(value: i64) -> noreturn` | longjmp to the innermost try with a thrown term; aborts when uncaught |
| `ex.term.catch_value` | `() -> i64` | the term delivered by the most recent throw (read from the catch region) |
| `ex.term.list_head` | `(list: i64) -> i64` | head; nil for empty/non-lists |
| `ex.term.list_tail` | `(list: i64) -> i64` | tail; nil for empty/non-lists |
| `ex.term.list_get` | `(list: i64, index: i64) -> i64` | element at index; nil for empty/non-lists or out of range |
| `ex.term.list_length` | `(list: i64) -> i64` | list length; 0 for nil |
| `ex.term.eq` | `(left: i64, right: i64) -> i64` | deep equality: exact for immediates, structural for containers |
| `ex.term.eq_loose` | `(left: i64, right: i64) -> i64` | BEAM-style loose equality: numeric int/float coercion, recursively structural for containers |
| `ex.term.binary_length` | `(binary: i64) -> i64` | byte length; 0 for non-binaries |
| `ex.term.binary_from_bytes` | `(bytes: ptr, length: i64) -> i64` | copies host bytes into a runtime-owned binary; nil on failure |
| `ex.term.binary_copy` | `(binary: i64, destination: ptr, capacity: i64) -> i64` | copies a binary into host storage; byte length or -1 on failure |
| `ex.term.binary_get` | `(binary: i64, index: i64) -> i64` | byte at index as a tagged int term; nil out of range / non-binary |
| `ex.term.binary_slice` | `(binary: i64, start: i64) -> i64` | materialized binary of bytes [start..len); nil for non-binaries / bad start |
| `ex.term.binary_utf8_get` | `(binary: i64, index: i64) -> i64` | UTF-8 codepoint at index as a tagged int term; nil for invalid/out-of-range |
| `ex.term.binary_utf8_width` | `(binary: i64, index: i64) -> i64` | UTF-8 codepoint byte width; 0 for invalid/out-of-range |
| `ex.term.binary_utf8_length` | `(binary: i64) -> i64` | UTF-8 codepoint count; invalid sequences count as one byte; 0 for non-binaries |
| `ex.term.string_printable` | `(binary: i64) -> i64` | 1 when every UTF-8 codepoint is printable under Elixir's `String.printable?/1` contract; 0 for invalid UTF-8 or non-binaries |
| `ex.term.binary_quote` | `(binary: i64) -> i64` | bounded Elixir string/binary inspection syntax; nil for non-binaries |
| `ex.term.binary_encode16` | `(binary: i64) -> i64` | uppercase hexadecimal binary of the bytes; nil for non-binaries |
| `ex.term.binary_decode16` | `(binary: i64) -> i64` | bytes from an uppercase hexadecimal binary; nil for non-binaries, odd lengths, or invalid digits |
| `ex.term.int_to_string` | `(word: i64) -> i64` | decimal binary of a tagged integer term; nil for non-integers |
| `ex.term.int_to_string_base` | `(word: i64, base: i64) -> i64` | base 2..36 uppercase binary of a tagged integer term; nil for non-integers / invalid base |
| `ex.term.int_to_hex` | `(word: i64) -> i64` | uppercase hexadecimal binary with `0x` prefix; nil for non-integers |
| `ex.term.string_to_int` | `(binary: i64) -> i64` | scalar i64 parsed from a decimal binary (optionally signed); 0 for invalid input or overflow |
| `ex.term.string_to_atom` | `(binary: i64) -> i64` | bounded runtime-local UTF-8 atom intern; integer-zero for invalid input, tagged integer one for limits |
| `ex.term.float_to_binary_short` | `(float: i64) -> i64` | BEAM-compatible shortest round-trip binary for a finite boxed float; nil for invalid terms |
| `ex.term.map_from_list` | `(list: i64) -> i64` | flat key/value list -> map |
| `ex.term.map_put` | `(map: i64, key: i64, value: i64) -> i64` | insert or replace a dynamic map entry |
| `ex.term.mapset_from_list` | `(list: i64) -> i64` | deduplicated set list (members keep their words) |
| `ex.term.mapset_member` | `(set: i64, member: i64) -> i64` | 1 when the set list contains the member word, else 0 |
| `ex.term.mapset_put` | `(set: i64, member: i64) -> i64` | set list with the member added (deduplicated) |
| `ex.term.file_read` | `(path: i64) -> i64` | file contents as a binary term; nil for missing files/non-binaries/oversized |
| `ex.term.file_read_lines` | `(path: i64) -> i64` | file contents split into line binaries (no trailing newlines); nil on read failure |
| `ex.term.binary_from_list` | `(list: i64) -> i64` | integer byte list -> binary |
| `ex.term.iodata_to_binary` | `(iodata: i64) -> i64` | recursively flatten nested byte lists and binaries; nil for invalid iodata |
| `ex.term.list_flatten` | `(list: i64) -> i64` | recursively flatten proper nested lists while preserving non-list leaves; integer-zero sentinel for invalid lists |
| `ex.term.is_integer` | `(word: i64) -> i64` | 1 if int |
| `ex.term.is_atom` | `(word: i64) -> i64` | 1 if atom (incl. nil) |
| `ex.term.is_binary` | `(word: i64) -> i64` | 1 if binary |
| `ex.term.is_list` | `(word: i64) -> i64` | 1 if list (incl. `[]`) |
| `ex.term.is_tuple` | `(word: i64) -> i64` | 1 if tuple |
| `ex.term.is_map` | `(word: i64) -> i64` | 1 if map |

Predicates return `1` or `0` as an `i64`.

## Constraints

- Immediate integers carry a 61-bit payload; values beyond that truncate.
- `ex.term.map_from_list` requires an even-length list.
- `ex.term.binary_from_list` reads each segment's integer payload as a byte.
- `ex.term.try_push` overflows at 16 nested try regions; deeper nesting aborts.
- A worker trampoline catches an otherwise uncaught `ex.term.throw`, records
  an abnormal process exit and continues running other actors. A throw outside
  an actor worker boundary still aborts.
- Each runtime grows through stable 512 KiB arena segments. A worker reserves
  its own current segment and allocates through a lock-free bump fast path;
  only segment acquisition/growth takes the runtime heap lock. Terms are
  immutable and remain valid after their allocating or sending process exits
  and its slot is recycled. Segment storage is retained and reset between
  executions; constructors return their documented nil/failure value only
  when allocation or the 128-segment (64 MiB at the default size) table is
  exhausted.
- Arena capacity has a 64 MiB hard limit. If an allocation has failed and the
  execution would otherwise return the ambiguous nil word, result creation
  returns the distinct `-2` OOM status. A later valid non-nil result remains
  observable for code paths that explicitly recover from a failed operation.
- Binary payloads are byte-packed after their `i64` length header, reducing
  payload storage from eight bytes per byte to one while keeping the tagged
  root pointer 8-byte aligned.
- Runtime reset and destroy require that no worker is entered. Heap allocation,
  process scheduling, counters, callbacks, actor state, and mailboxes are
  synchronized while a runtime is shared by entered workers.
- Each mailbox is backed by one ordered signal queue. Message envelopes retain
  their sender and a monotonically increasing arrival sequence; exit and DOWN
  signals will use the same queue. Public receive operations currently expose
  message payloads only.
- Links and monitors are bounded to 32 relations per process in this runtime
  slice. Compiled code supplies the hashed `EXIT`, `DOWN`, `process`, and
  `normal` atom words because atom identifiers belong to the program ABI.
- Operations that need multiple locks acquire them in the global order
  scheduler, mailbox, then process state.
- A selective receive parks only while the mailbox length is not beyond its
  completed scan cursor. Send appends before waking the actor, establishing
  the mailbox happens-before edge and preventing lost wakeups.
- The mailbox is a fixed 64-slot FIFO for a single actor; blocking receives
  and `after` timeouts arrive with the scheduler.

## Building

The standalone library root uses `TermRuntime.Extension` to reflect over the
runtime namespace, validate every selected C ABI function at comptime, and map
`ex_term_*` declarations to the documented `ex.term.*` surface. Host adapters
use the same contract with their own declaration-to-symbol mapper.

```sh
zig build term-runtime-shared --prefix priv/term_runtime -Doptimize=ReleaseSafe
```

`-lc` links libc so the runtime can reference `setjmp`/`longjmp` for
`try`/`throw`; `Batata.TermRuntime.ensure_built!/0` passes it automatically.

`Batata.TermRuntime.ensure_built!/0` wraps this and is used by
`Batata.execute/2` (JIT) through `shared_lib_paths`.
