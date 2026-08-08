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

Heap objects are 8-byte aligned, so the low 3 bits of a container pointer are
always zero and the tag can be OR-ed in. `nil` is the atom with id 0
(`word == 1`); it doubles as the empty list, matching BEAM.

Heap layouts (all fields are `i64` words):

```
tuple:  [len] [elem × len]
map:    [len] [entry × 2*len]   (flat key/value pairs; len = pair count)
binary: [len] [byte × len]
list:   cons cells [head] [tail]
```

## Intrinsics

All functions use the C ABI and return/accept `i64` tagged words unless noted.

| symbol | signature | semantics |
| --- | --- | --- |
| `ex.term.list_cons` | `(head: i64, tail: i64) -> i64` | cons a word onto a list |
| `ex.term.tuple_from_list` | `(list: i64) -> i64` | proper list -> tuple |
| `ex.term.tuple_get` | `(tuple: i64, index: i64) -> i64` | element at index; nil when out of range or not a tuple |
| `ex.term.tuple_length` | `(tuple: i64) -> i64` | tuple arity; 0 for non-tuples |
| `ex.term.list_head` | `(list: i64) -> i64` | head; nil for empty/non-lists |
| `ex.term.list_tail` | `(list: i64) -> i64` | tail; nil for empty/non-lists |
| `ex.term.list_length` | `(list: i64) -> i64` | list length; 0 for nil |
| `ex.term.eq` | `(left: i64, right: i64) -> i64` | deep equality: exact for immediates, structural for containers |
| `ex.term.binary_length` | `(binary: i64) -> i64` | byte length; 0 for non-binaries |
| `ex.term.binary_get` | `(binary: i64, index: i64) -> i64` | byte at index as a tagged int term; nil out of range / non-binary |
| `ex.term.binary_slice` | `(binary: i64, start: i64) -> i64` | materialized binary of bytes [start..len); nil for non-binaries / bad start |
| `ex.term.binary_utf8_get` | `(binary: i64, index: i64) -> i64` | UTF-8 codepoint at index as a tagged int term; nil for invalid/out-of-range |
| `ex.term.binary_utf8_width` | `(binary: i64, index: i64) -> i64` | UTF-8 codepoint byte width; 0 for invalid/out-of-range |
| `ex.term.map_from_list` | `(list: i64) -> i64` | flat key/value list -> map |
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
- The runtime owns a fixed bump arena; GC is a later milestone.

## Building

```sh
zig build-lib native/term_runtime.zig -dynamic -O ReleaseSafe -femit-bin=priv/term_runtime/libterm_runtime.so
```

`Batata.TermRuntime.ensure_built!/0` wraps this and is used by
`Batata.execute/2` (JIT) through `shared_lib_paths`.
