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

Heap objects are 8-byte aligned, so the low 3 bits of a container pointer are
always zero and the tag can be OR-ed in. `nil` is the atom with id 0
(`word == 1`); it doubles as the empty list, matching BEAM.

Heap layouts (all fields are `i64` words):

```
tuple:  [len] [elem × len]
map:    [len] [entry × 2*len]   (flat key/value pairs; len = pair count)
binary: [len] [byte × len]
list:   cons cells [head] [tail]
fun:    [fn_idx] [env_len] [env × env_len]
```

## Intrinsics

All functions use the C ABI and return/accept `i64` tagged words unless noted.

| symbol | signature | semantics |
| --- | --- | --- |
| `ex.term.list_cons` | `(head: i64, tail: i64) -> i64` | cons a word onto a list |
| `ex.term.self` | `() -> i64` | pid of the current actor (atom word with id 1) |
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
| `ex.term.spawn` | `(fun: i64) -> i64` | create a new process with its own mailbox/clock and the given closure entry; returns its pid (atom), nil when the process table is full (capacity 8) |
| `ex.term.process_table_reset` | `() -> i64` | reset the process table to a single fresh initial process; the scheduler driver calls this at program start |
| `ex.term.cont_save` | `(arg: i64, acc: i64, cursor: i64) -> i64` | save the current process's cursor-loop continuation at the current epoch |
| `ex.term.cont_pending` | `() -> i64` | 1 when a continuation is saved at the current epoch (a stale epoch reads 0, so the entry restarts) |
| `ex.term.cont_active` | `() -> i64` | 1 when any continuation is saved (valid or stale); the entry's mailbox reset is gated on this so a resume keeps messages that arrived while suspended |
| `ex.term.cont_clear` | `() -> i64` | clear the saved continuation |
| `ex.term.cont_load_arg` / `cont_load_acc` / `cont_load_cursor` | `() -> i64` | saved loop state; nil when none is pending |
| `ex.term.receive_cont_save` | `(arg: i64, acc: i64, cursor: i64) -> i64` | save a selective-receive scan continuation; a message arrival invalidates it (epoch bump), unlike a cursor-loop continuation |
| `ex.term.schedule_next` | `() -> i64` | round-robin to the next runnable process and return its pid |
| `ex.term.current_entry` | `() -> i64` | closure word of the current process's entry; 0 for the compiled entry process |
| `ex.term.process_done` | `(result: i64) -> i64` | mark the current process done and store its result |
| `ex.term.processes_runnable` | `() -> i64` | number of runnable processes (the driver loops while > 0) |
| `ex.term.process_result` | `(pid: i64) -> i64` | result of a completed process; nil when unknown or still runnable |
| `ex.term.clock_init` | `(budget: i64) -> i64` | set the reduction budget and reset the used counter |
| `ex.term.clock_tick` | `(cost: i64) -> i64` | charge reductions; 1 when the budget is exhausted (yield), else 0 |
| `ex.term.clock_budget_left` | `() -> i64` | remaining budget clamped to >= 0; -1 when no budget is set |
| `ex.term.clock_epoch` | `() -> i64` | current continuation-generation counter |
| `ex.term.clock_bump_epoch` | `() -> i64` | bump the epoch (message arrival / scheduler round); returns the new value |
| `ex.term.yield_mark` | `() -> i64` | record one preemptive yield at a slice boundary; returns the yield count |
| `ex.term.yield_count` | `() -> i64` | number of preemptive yields so far |
| `ex.term.to_int` | `(word: i64) -> i64` | untag an integer term to its scalar value; 0 for non-integers |
| `ex.term.make_fun` | `(fn_idx: i64, env_len: i64, e0..e3: i64) -> i64` | closure word referencing `__fn_*` by index with up to four captured env words |
| `ex.term.fun_idx` | `(fun: i64) -> i64` | function index of a closure; 0 for non-functions |
| `ex.term.fun_env` | `(fun: i64, index: i64) -> i64` | captured env word at index; nil for non-functions / out-of-range |
| `ex.term.tuple_from_list` | `(list: i64) -> i64` | proper list -> tuple |
| `ex.term.tuple_get` | `(tuple: i64, index: i64) -> i64` | element at index; nil when out of range or not a tuple |
| `ex.term.tuple_length` | `(tuple: i64) -> i64` | tuple arity; 0 for non-tuples |
| `ex.term.map_length` | `(map: i64) -> i64` | map pair count; 0 for non-maps |
| `ex.term.enumerable_count` | `(word: i64) -> i64` | element count by tag: list length / tuple arity / map pairs / binary bytes; 0 otherwise |
| `ex.term.enumerable_to_list` | `(word: i64) -> i64` | materialize by tag: list identity, tuple elements, map `{k, v}` pairs, binary byte terms; nil for unsupported tags |
| `ex.term.enumerable_to_list_range` | `(start: i64, stop: i64) -> i64` | materialize an inclusive integer range as a list |
| `ex.term.enumerable_reduce` | `(enumerable: i64, acc: i64, continuation: i64) -> i64` | tag-dispatched reduce over list/tuple/binary/map; continuation 1 = sum, 2 = return acc, 3 = map values sum, 4 = map keys sum, 5 = map entries sum, 6 = product, 7 = acc - item, 8 = item - acc, 9 = div(acc, item), 10 = div(item, acc), 11 = rem(acc, item), 12 = rem(item, acc); zero divisor yields 0 |
| `ex.term.enumerable_reduce_c` | `(enumerable: i64, acc: i64, continuation: i64, capture: i64) -> i64` | closure-shaped reduce with a captured scalar; continuation 13 = sum with capture (acc + item + capture), 14 = product with capture (acc + item * capture) |
| `ex.term.enumerable_reduce_range` | `(start: i64, stop: i64, acc: i64, continuation: i64) -> i64` | inclusive integer range reduce (ascending or descending), reusing the continuation table (15 = count, acc + 1 per item) |
| `ex.term.enumerable_reduce_fun` | `(enumerable: i64, acc: i64, reducer_addr: i64) -> i64` | reduce by calling a compiled reducer `(item, acc) -> acc` on each item (list/tuple/binary); items are untagged integers |
| `ex.term.enumerable_map_fun` | `(enumerable: i64, mapper_addr: i64) -> i64` | map by calling a compiled mapper `(item) -> i64` on each item, producing a list in order |
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
| `ex.term.binary_length` | `(binary: i64) -> i64` | byte length; 0 for non-binaries |
| `ex.term.binary_get` | `(binary: i64, index: i64) -> i64` | byte at index as a tagged int term; nil out of range / non-binary |
| `ex.term.binary_slice` | `(binary: i64, start: i64) -> i64` | materialized binary of bytes [start..len); nil for non-binaries / bad start |
| `ex.term.binary_utf8_get` | `(binary: i64, index: i64) -> i64` | UTF-8 codepoint at index as a tagged int term; nil for invalid/out-of-range |
| `ex.term.binary_utf8_width` | `(binary: i64, index: i64) -> i64` | UTF-8 codepoint byte width; 0 for invalid/out-of-range |
| `ex.term.binary_utf8_length` | `(binary: i64) -> i64` | UTF-8 codepoint count; invalid sequences count as one byte; 0 for non-binaries |
| `ex.term.binary_encode16` | `(binary: i64) -> i64` | uppercase hexadecimal binary of the bytes; nil for non-binaries |
| `ex.term.binary_decode16` | `(binary: i64) -> i64` | bytes from an uppercase hexadecimal binary; nil for non-binaries, odd lengths, or invalid digits |
| `ex.term.int_to_string` | `(word: i64) -> i64` | decimal binary of a tagged integer term; nil for non-integers |
| `ex.term.string_to_int` | `(binary: i64) -> i64` | scalar i64 parsed from a decimal binary (optionally signed); 0 for invalid input or overflow |
| `ex.term.map_from_list` | `(list: i64) -> i64` | flat key/value list -> map |
| `ex.term.mapset_from_list` | `(list: i64) -> i64` | deduplicated set list (members keep their words) |
| `ex.term.mapset_member` | `(set: i64, member: i64) -> i64` | 1 when the set list contains the member word, else 0 |
| `ex.term.mapset_put` | `(set: i64, member: i64) -> i64` | set list with the member added (deduplicated) |
| `ex.term.file_read` | `(path: i64) -> i64` | file contents as a binary term; nil for missing files/non-binaries/oversized |
| `ex.term.file_read_lines` | `(path: i64) -> i64` | file contents split into line binaries (no trailing newlines); nil on read failure |
| `ex.term.binary_from_list` | `(list: i64) -> i64` | integer byte list -> binary |
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
- An uncaught `ex.term.throw` panics.
- The runtime owns a fixed bump arena; GC is a later milestone.
- The mailbox is a fixed 64-slot FIFO for a single actor; blocking receives
  and `after` timeouts arrive with the scheduler.

## Building

```sh
zig build-lib native/term_runtime.zig -dynamic -O ReleaseSafe -femit-bin=priv/term_runtime/libterm_runtime.so -lc
```

`-lc` links libc so the runtime can reference `setjmp`/`longjmp` for
`try`/`throw`; `Batata.TermRuntime.ensure_built!/0` passes it automatically.

`Batata.TermRuntime.ensure_built!/0` wraps this and is used by
`Batata.execute/2` (JIT) through `shared_lib_paths`.
