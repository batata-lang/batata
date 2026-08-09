//! Zig term runtime for the `ex` dialect.
//!
//! Implements the declaration-first ABI in `native/ABI.md`. All exported
//! symbols are C ABI functions over 64-bit tagged words; Beaver's ex
//! conversion plan emits calls to exactly these symbols.

const std = @import("std");
const c = @cImport({
    @cInclude("setjmp.h");
});

// Tag layout: the low 3 bits of a 64-bit word. Immediate terms carry their
// payload in the upper 61 bits; heap-backed containers carry an 8-byte-aligned
// pointer.
const tag_int: usize = 0;
const tag_atom: usize = 1;
const tag_tuple: usize = 2;
const tag_list: usize = 3;
const tag_map: usize = 4;
const tag_binary: usize = 5;
const tag_fun: usize = 6;

const tag_mask: usize = 7;
const tag_shift: u6 = 3;

/// Nil is the atom term with id 0: tag_atom | (0 << 3).
const nil_word: i64 = 1;

// Heap layouts (all 8-byte aligned words):
//   tuple:  [len: i64] [elem: i64 ... len]
//   map:    [len: i64] [entry: i64 ... 2*len]   (flat key/value pairs)
//   binary: [len: i64] [byte: i64 ... len]
//   list:   cons cells [head: i64] [tail: i64]
//   fun:    [fn_idx: i64] [env_len: i64] [env: i64 ... env_len]

// A fixed bump arena. M2 scope: term construction and predicates for small
// literal programs; GC arrives with a later milestone.
var heap: [32 * 1024 * 1024]u8 align(8) = undefined;
var bump: usize = 0;

fn alloc_bytes(len: usize) ?[*]u8 {
    const start = std.mem.alignForward(usize, bump, @alignOf(i64));
    if (start + len > heap.len) return null;
    bump = start + len;
    return heap[start..][0..len].ptr;
}

fn alloc_words(count: usize) ?[*]i64 {
    return @ptrCast(@alignCast(alloc_bytes(count * @sizeOf(i64))));
}

fn word_tag(word: i64) usize {
    return @as(usize, @bitCast(word)) & tag_mask;
}

fn word_from_ptr(ptr: anytype, comptime tag: usize) i64 {
    const tagged = @intFromPtr(ptr) | tag;
    return @bitCast(tagged);
}

fn word_payload(word: i64) i64 {
    return @divTrunc(word, @as(i64, 1) << @intCast(tag_shift));
}

fn is_int(word: i64) bool {
    return word_tag(word) == tag_int;
}

fn is_atom(word: i64) bool {
    return word_tag(word) == tag_atom;
}

fn is_list_word(word: i64) bool {
    // [] (the empty list) is represented as the nil atom, matching BEAM.
    return word == nil_word or word_tag(word) == tag_list;
}

fn list_len(list: i64) usize {
    var current = list;
    var count: usize = 0;
    while (word_tag(current) == tag_list) {
        const cell = list_cell(current);
        count += 1;
        current = cell[1];
    }
    return count;
}

fn list_cell(list: i64) *[2]i64 {
    return @ptrFromInt(@as(usize, @bitCast(list)) & ~tag_mask);
}

fn copy_list_into(dst: []i64, list: i64) void {
    var current = list;
    var i: usize = 0;
    while (word_tag(current) == tag_list) {
        const cell = list_cell(current);
        dst[i] = cell[0];
        i += 1;
        current = cell[1];
    }
}

fn tuple_len(tuple: i64) usize {
    const header: *[1]i64 = @ptrFromInt(@as(usize, @bitCast(tuple)) & ~tag_mask);
    return @intCast(header[0]);
}

fn tuple_elems(tuple: i64) [*]i64 {
    return @ptrFromInt((@as(usize, @bitCast(tuple)) & ~tag_mask) + @sizeOf(i64));
}

fn binary_len(binary: i64) usize {
    const header: *[1]i64 = @ptrFromInt(@as(usize, @bitCast(binary)) & ~tag_mask);
    return @intCast(header[0]);
}

fn binary_bytes(binary: i64) [*]i64 {
    return @ptrFromInt((@as(usize, @bitCast(binary)) & ~tag_mask) + @sizeOf(i64));
}

fn map_len(map: i64) usize {
    const header: *[1]i64 = @ptrFromInt(@as(usize, @bitCast(map)) & ~tag_mask);
    return @intCast(header[0]);
}

fn map_entries(map: i64) [*]i64 {
    return @ptrFromInt((@as(usize, @bitCast(map)) & ~tag_mask) + @sizeOf(i64));
}

fn fun_words(fun: i64) [*]i64 {
    return @ptrFromInt(@as(usize, @bitCast(fun)) & ~tag_mask);
}

// A fixed-capacity FIFO mailbox for the current execution context. M4 scope:
// a single actor consumes messages through `receive`; blocking and `after`
// timeouts arrive with the scheduler.
const mailbox_cap: usize = 64;
var mailbox: [mailbox_cap]i64 = undefined;
var mailbox_head: usize = 0;
var mailbox_len: usize = 0;

fn mailbox_push(msg: i64) bool {
    if (mailbox_len >= mailbox_cap) return false;
    const index = (mailbox_head + mailbox_len) % mailbox_cap;
    mailbox[index] = msg;
    mailbox_len += 1;
    return true;
}

fn mailbox_pop() ?i64 {
    if (mailbox_len == 0) return null;
    const msg = mailbox[mailbox_head];
    mailbox_head = (mailbox_head + 1) % mailbox_cap;
    mailbox_len -= 1;
    return msg;
}

// A stack of setjmp buffers for non-local exits (`throw`). The setjmp call
// itself happens in the compiled code (so its frame stays live); the runtime
// only tracks the buffers and performs the longjmp. The scalar slice has no
// stack-owned resources to clean up, so a plain longjmp is safe.
var jmp_stack: [16]*c.jmp_buf = undefined;
var jmp_depth: usize = 0;
var throw_value: i64 = 0;

/// Size of the C `jmp_buf` so the compiled code can allocate it on its own
/// stack.
pub export fn ex_term_jmp_buf_size() i64 {
    return @sizeOf(c.jmp_buf);
}

/// Address of libc's `setjmp`, so the compiled code can call it indirectly
/// without the ORC linker resolving libc symbols.
pub export fn ex_term_setjmp_addr() i64 {
    return @bitCast(@intFromPtr(&c.setjmp));
}

/// Pushes a setjmp buffer for a try region.
pub export fn ex_term_try_push(buf: *c.jmp_buf) i64 {
    if (jmp_depth >= jmp_stack.len) return -1;
    jmp_stack[jmp_depth] = buf;
    jmp_depth += 1;
    return 0;
}

/// Pops the innermost try region's setjmp buffer.
pub export fn ex_term_try_pop() i64 {
    if (jmp_depth > 0) jmp_depth -= 1;
    return 0;
}

/// Throws a value to the innermost try region. Uncaught throws abort.
pub export fn ex_term_throw(value: i64) noreturn {
    throw_value = value;
    if (jmp_depth == 0) @panic("uncaught throw");
    c.longjmp(jmp_stack[jmp_depth - 1], 1);
}

/// Returns the value delivered by the most recent throw (called from the
/// catch region after the longjmp returns).
pub export fn ex_term_catch_value() i64 {
    return throw_value;
}

/// Returns the pid of the current execution context. The scalar slice runs a
/// single actor with pid 1 (the atom term with id 1).
pub export fn ex_term_self() i64 {
    return @as(i64, @intCast(1 << @intCast(tag_shift))) | @as(i64, @intCast(tag_atom));
}

/// Enqueues a message. The single-actor slice accepts any pid and returns the
/// message itself (matching BEAM's `send/2`); returns nil when the mailbox is
/// full.
pub export fn ex_term_send(pid: i64, msg: i64) i64 {
    _ = pid;
    if (!mailbox_push(msg)) return nil_word;
    return msg;
}

/// Dequeues the oldest message; nil when the mailbox is empty.
pub export fn ex_term_receive() i64 {
    return mailbox_pop() orelse nil_word;
}

/// Resets the mailbox. The compiled entry function calls this on startup so
/// each program run observes a fresh actor.
pub export fn ex_term_mailbox_clear() i64 {
    mailbox_head = 0;
    mailbox_len = 0;
    return nil_word;
}

/// Untags an integer term word to its scalar value; 0 for non-integers (the
/// caller is expected to have checked `is_integer` first).
pub export fn ex_term_to_int(word: i64) i64 {
    if (word_tag(word) != tag_int) return 0;
    return word_payload(word);
}

/// Constructs a first-class function value: a closure word holding the index
/// of the extracted `__fn_*` and up to four captured env words.
pub export fn ex_term_make_fun(fn_idx: i64, env_len: i64, e0: i64, e1: i64, e2: i64, e3: i64) i64 {
    if (env_len < 0 or env_len > 4) return nil_word;
    const words = alloc_words(6) orelse return nil_word;
    words[0] = fn_idx;
    words[1] = env_len;
    const env = [4]i64{ e0, e1, e2, e3 };
    for (0..@as(usize, @intCast(env_len))) |i| words[2 + i] = env[i];
    return word_from_ptr(words, tag_fun);
}

/// Returns the function index of a closure word; 0 for non-functions.
pub export fn ex_term_fun_idx(fun: i64) i64 {
    if (word_tag(fun) != tag_fun) return 0;
    return fun_words(fun)[0];
}

/// Returns the `index`-th captured env word of a closure; nil for
/// non-functions or out-of-range indices.
pub export fn ex_term_fun_env(fun: i64, index: i64) i64 {
    if (word_tag(fun) != tag_fun) return nil_word;
    const words = fun_words(fun);
    const env_len: usize = @intCast(words[1]);
    if (index < 0 or index >= @as(i64, @intCast(env_len))) return nil_word;
    return words[2 + @as(usize, @intCast(index))];
}

/// Conses a head word onto a list tail, returning a proper list word.
pub export fn ex_term_list_cons(head: i64, tail: i64) i64 {
    const cell = alloc_words(2) orelse return nil_word;
    cell[0] = head;
    cell[1] = tail;
    return word_from_ptr(cell, tag_list);
}

/// Converts a proper list word into a tuple word.
pub export fn ex_term_tuple_from_list(list: i64) i64 {
    const len = list_len(list);
    const tuple = alloc_words(len + 1) orelse return nil_word;
    tuple[0] = @intCast(len);
    copy_list_into(tuple[1 .. len + 1], list);
    return word_from_ptr(tuple, tag_tuple);
}

/// Reads the element at `index` from a tuple word; nil for out-of-range or
/// non-tuples (the caller is expected to have checked `is_tuple` first).
pub export fn ex_term_tuple_get(tuple: i64, index: i64) i64 {
    if (word_tag(tuple) != tag_tuple) return nil_word;
    const len = tuple_len(tuple);
    if (index < 0 or index >= @as(i64, @intCast(len))) return nil_word;
    return tuple_elems(tuple)[@intCast(index)];
}

/// Returns the arity of a tuple word; 0 for non-tuples.
pub export fn ex_term_tuple_length(tuple: i64) i64 {
    if (word_tag(tuple) != tag_tuple) return 0;
    return @intCast(tuple_len(tuple));
}

/// Returns the pair count of a map word; 0 for non-maps.
pub export fn ex_term_map_length(map: i64) i64 {
    if (word_tag(map) != tag_map) return 0;
    return @intCast(map_len(map));
}

/// Returns the element count of an enumerable term: list length, tuple
/// arity, map pair count, or binary byte length; 0 for non-enumerables.
pub export fn ex_term_enumerable_count(word: i64) i64 {
    return switch (word_tag(word)) {
        tag_list => @intCast(list_len(word)),
        tag_tuple => @intCast(tuple_len(word)),
        tag_map => @intCast(map_len(word)),
        tag_binary => @intCast(binary_len(word)),
        else => 0,
    };
}

/// Materializes an enumerable as a list by term tag: lists pass through,
/// tuples yield their elements, maps yield `{k, v}` tuple pairs, binaries
/// yield tagged byte integers. nil for unsupported tags.
pub export fn ex_term_enumerable_to_list(enumerable: i64) i64 {
    switch (word_tag(enumerable)) {
        tag_list => return enumerable,
        tag_tuple => {
            const len = tuple_len(enumerable);
            var result = nil_word;
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                result = ex_term_list_cons(tuple_elems(enumerable)[i], result);
            }
            return result;
        },
        tag_map => {
            const len = map_len(enumerable);
            var result = nil_word;
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                const key = map_entries(enumerable)[i * 2];
                const value = map_entries(enumerable)[i * 2 + 1];
                const pair = alloc_words(3) orelse return nil_word;
                pair[0] = 2;
                pair[1] = key;
                pair[2] = value;
                result = ex_term_list_cons(word_from_ptr(pair, tag_tuple), result);
            }
            return result;
        },
        tag_binary => {
            const len = binary_len(enumerable);
            var result = nil_word;
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                result = ex_term_list_cons(
                    binary_bytes(enumerable)[i] << @intCast(tag_shift),
                    result,
                );
            }
            return result;
        },
        else => return nil_word,
    }
}

/// Materializes an inclusive integer range as a list.
pub export fn ex_term_enumerable_to_list_range(start: i64, stop: i64) i64 {
    var result = nil_word;
    if (start <= stop) {
        var i = stop;
        while (i >= start) : (i -= 1) {
            result = ex_term_list_cons(i << @intCast(tag_shift), result);
        }
    } else {
        var i = stop;
        while (i <= start) : (i += 1) {
            result = ex_term_list_cons(i << @intCast(tag_shift), result);
        }
    }
    return result;
}

/// Reduces an enumerable (list / tuple / binary) by term tag. `continuation`
/// selects the step: 1 = sum (acc + item as i64), 2 = return the accumulator
/// unchanged, 3 = map values sum (acc + each entry value), 4 = map keys sum
/// (acc + each entry key), 5 = map entries sum (acc + key + value per entry).
/// 6 = product (acc * item). Items are untagged integers (binary bytes are
/// tagged before the step, matching list/tuple elements). 7 = acc - item,
/// 8 = item - acc (subtraction is order-sensitive). 9-12 are the integer
/// div/rem variants (order-sensitive, zero divisor yields 0).
pub export fn ex_term_enumerable_reduce(enumerable: i64, acc: i64, continuation: i64) i64 {
    switch (word_tag(enumerable)) {
        tag_list => {
            var current = enumerable;
            var result = acc;
            while (word_tag(current) == tag_list) {
                result = enumerate_step(result, list_cell(current)[0], continuation);
                current = list_cell(current)[1];
            }
            return result;
        },
        tag_tuple => {
            const len = tuple_len(enumerable);
            var result = acc;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                result = enumerate_step(result, tuple_elems(enumerable)[i], continuation);
            }
            return result;
        },
        tag_binary => {
            const len = binary_len(enumerable);
            var result = acc;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const byte: i64 = binary_bytes(enumerable)[i];
                result = enumerate_step(result, byte << @intCast(tag_shift), continuation);
            }
            return result;
        },
        tag_map => {
            const len = map_len(enumerable);
            const entries = map_entries(enumerable);
            var result = acc;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const key = entries[i * 2];
                const value = entries[i * 2 + 1];
                if (continuation == 5) {
                    result += word_value(key) + word_value(value);
                } else {
                    const item = if (continuation == 4) key else value;
                    result = enumerate_step(result, item, continuation);
                }
            }
            return result;
        },
        else => return acc,
    }
}

fn enumerate_step(acc: i64, item: i64, continuation: i64) i64 {
    if (continuation == 1 or continuation == 3 or continuation == 4) { // sum variants
        return acc + word_value(item);
    } else if (continuation == 6) { // product
        return acc * word_value(item);
    } else if (continuation == 7) { // acc - item
        return acc - word_value(item);
    } else if (continuation == 8) { // item - acc
        return word_value(item) - acc;
    } else if (continuation == 9) { // div(acc, item)
        const item_v = word_value(item);
        return if (item_v == 0) 0 else @divTrunc(acc, item_v);
    } else if (continuation == 10) { // div(item, acc)
        return if (acc == 0) 0 else @divTrunc(word_value(item), acc);
    } else if (continuation == 11) { // rem(acc, item)
        const item_v = word_value(item);
        return if (item_v == 0) 0 else @rem(acc, item_v);
    } else if (continuation == 12) { // rem(item, acc)
        return if (acc == 0) 0 else @rem(word_value(item), acc);
    } else if (continuation == 15) { // count: acc + 1 per item
        return acc + 1;
    }
    return acc; // return-accumulator
}

fn word_value(word: i64) i64 {
    return if (is_int(word)) word_payload(word) else 0;
}

/// Closure-shaped enumerable reduce: a captured scalar participates in the
/// step. continuation 13 = sum with capture (acc + item + capture). The
/// capture is the reducer's captured environment (a scalar i64 word).
pub export fn ex_term_enumerable_reduce_c(
    enumerable: i64,
    acc: i64,
    continuation: i64,
    capture: i64,
) i64 {
    if (continuation == 14) {
        // product with capture: acc + item * capture
        switch (word_tag(enumerable)) {
            tag_list => {
                var current = enumerable;
                var result = acc;
                while (word_tag(current) == tag_list) {
                    result += word_value(list_cell(current)[0]) * capture;
                    current = list_cell(current)[1];
                }
                return result;
            },
            tag_tuple => {
                const len = tuple_len(enumerable);
                var result = acc;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    result += word_value(tuple_elems(enumerable)[i]) * capture;
                }
                return result;
            },
            tag_binary => {
                const len = binary_len(enumerable);
                var result = acc;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    result += binary_bytes(enumerable)[i] * capture;
                }
                return result;
            },
            else => return acc,
        }
    }
    if (continuation != 13) return ex_term_enumerable_reduce(enumerable, acc, continuation);
    switch (word_tag(enumerable)) {
        tag_list => {
            var current = enumerable;
            var result = acc;
            while (word_tag(current) == tag_list) {
                result += word_value(list_cell(current)[0]) + capture;
                current = list_cell(current)[1];
            }
            return result;
        },
        tag_tuple => {
            const len = tuple_len(enumerable);
            var result = acc;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                result += word_value(tuple_elems(enumerable)[i]) + capture;
            }
            return result;
        },
        tag_binary => {
            const len = binary_len(enumerable);
            var result = acc;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                result += binary_bytes(enumerable)[i] + capture;
            }
            return result;
        },
        else => return acc,
    }
}

/// Reduces an inclusive integer range (ascending or descending) by
/// continuation, reusing the enumerable_reduce continuation table.
pub export fn ex_term_enumerable_reduce_range(
    start: i64,
    stop: i64,
    acc: i64,
    continuation: i64,
) i64 {
    var result = acc;
    if (start <= stop) {
        var i = start;
        while (i <= stop) : (i += 1) {
            result = enumerate_step(result, i << @intCast(tag_shift), continuation);
        }
    } else {
        var i = start;
        while (i >= stop) : (i -= 1) {
            result = enumerate_step(result, i << @intCast(tag_shift), continuation);
        }
    }
    return result;
}

/// Reduces an enumerable by calling an arbitrary reducer function
/// `(item: i64, acc: i64) -> i64` (compiled by the frontend) on each item.
/// The reducer address is passed as an i64. Items are untagged integers
/// (binary bytes are raw).
pub export fn ex_term_enumerable_reduce_fun(
    enumerable: i64,
    acc: i64,
    reducer: ?*const fn (i64, i64) callconv(.c) i64,
) i64 {
    switch (word_tag(enumerable)) {
        tag_list => {
            var current = enumerable;
            var result = acc;
            while (word_tag(current) == tag_list) {
                result = reducer.?(word_value(list_cell(current)[0]), result);
                current = list_cell(current)[1];
            }
            return result;
        },
        tag_tuple => {
            const len = tuple_len(enumerable);
            var result = acc;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                result = reducer.?(word_value(tuple_elems(enumerable)[i]), result);
            }
            return result;
        },
        tag_binary => {
            const len = binary_len(enumerable);
            var result = acc;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                result = reducer.?(binary_bytes(enumerable)[i], result);
            }
            return result;
        },
        else => return acc,
    }
}

// Native callback registry (protocol dispatch contract, expandable route):
// the runtime owns a table of registered callback entry points
// (fn_id -> function pointer). Compiled impls (e.g. enumerable count/reduce
// for external types) register through `ex.term.register_callback`; compiled
// code calls them through `ex.term.call_callback`. Unregistered ids return
// the error sentinel -1.
const beam_callback_cap = 16;
var callbacks: [beam_callback_cap]?*const fn (i64) callconv(.c) i64 = [_]?*const fn (i64) callconv(.c) i64{null} ** beam_callback_cap;

/// Registers a native callback entry (fn_id, function pointer). Returns 0 on
/// success, -1 when the id is out of range.
pub export fn ex_term_register_callback(
    fn_id: i64,
    callback: ?*const fn (i64) callconv(.c) i64,
) i64 {
    if (fn_id < 0 or fn_id >= beam_callback_cap) return -1;
    callbacks[@intCast(fn_id)] = callback;
    return 0;
}

/// Calls a registered native callback entry with an argument word; -1 when
/// the id is out of range or not registered.
pub export fn ex_term_call_callback(fn_id: i64, arg: i64) i64 {
    if (fn_id < 0 or fn_id >= beam_callback_cap) return -1;
    const callback = callbacks[@intCast(fn_id)] orelse return -1;
    return callback(arg);
}

/// Returns the head of a list word; nil for non-lists or the empty list.
pub export fn ex_term_list_head(list: i64) i64 {
    if (word_tag(list) != tag_list) return nil_word;
    return list_cell(list)[0];
}

/// Returns the tail of a list word; nil for non-lists or the empty list.
pub export fn ex_term_list_tail(list: i64) i64 {
    if (word_tag(list) != tag_list) return nil_word;
    return list_cell(list)[1];
}

/// Returns the element at index of a list word; nil when out of range or
/// not a list.
pub export fn ex_term_list_get(list: i64, index: i64) i64 {
    if (word_tag(list) != tag_list) return nil_word;
    var cell = list_cell(list);
    var i: i64 = 0;
    while (i < index) : (i += 1) {
        const tail = cell[1];
        if (word_tag(tail) != tag_list) return nil_word;
        cell = list_cell(tail);
    }
    return cell[0];
}

/// Returns the length of a list word (0 for nil, the empty list).
pub export fn ex_term_list_length(list: i64) i64 {
    return @intCast(list_len(list));
}

/// Deep equality: exact for immediate terms, structural for containers
/// (tuples, lists, maps, binaries). Terms are immutable on the bump heap, so
/// no cycle handling is needed.
pub export fn ex_term_eq(left: i64, right: i64) i64 {
    return if (term_eq(left, right)) 1 else 0;
}

fn term_eq(left: i64, right: i64) bool {
    if (left == right) return true;
    const ltag = word_tag(left);
    if (ltag != word_tag(right)) return false;

    switch (ltag) {
        tag_tuple => {
            if (tuple_len(left) != tuple_len(right)) return false;
            const n = tuple_len(left);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (!term_eq(tuple_elems(left)[i], tuple_elems(right)[i])) return false;
            }
            return true;
        },
        tag_list => {
            if (list_len(left) != list_len(right)) return false;
            var a = left;
            var b = right;
            while (word_tag(a) == tag_list) {
                if (!term_eq(list_cell(a)[0], list_cell(b)[0])) return false;
                a = list_cell(a)[1];
                b = list_cell(b)[1];
            }
            return true;
        },
        tag_map => {
            if (map_len(left) != map_len(right)) return false;
            const n = map_len(left);
            var i: usize = 0;
            while (i < 2 * n) : (i += 1) {
                if (!term_eq(map_entries(left)[i], map_entries(right)[i])) return false;
            }
            return true;
        },
        tag_binary => {
            if (binary_len(left) != binary_len(right)) return false;
            const n = binary_len(left);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (binary_bytes(left)[i] != binary_bytes(right)[i]) return false;
            }
            return true;
        },
        else => return false,
    }
}

/// Returns the byte length of a binary word; 0 for non-binaries.
pub export fn ex_term_binary_length(binary: i64) i64 {
    if (word_tag(binary) != tag_binary) return 0;
    return @intCast(binary_len(binary));
}

/// Reads the byte at `index` as a tagged int term; nil for out-of-range or
/// non-binaries (the caller is expected to have checked `is_binary` first).
pub export fn ex_term_binary_get(binary: i64, index: i64) i64 {
    if (word_tag(binary) != tag_binary) return nil_word;
    const len = binary_len(binary);
    if (index < 0 or index >= @as(i64, @intCast(len))) return nil_word;
    const byte: i64 = binary_bytes(binary)[@intCast(index)];
    return (byte & 0xFF) << @intCast(tag_shift);
}

/// Materializes a new binary word from bytes [start..len); nil for
/// non-binaries or an out-of-range start.
pub export fn ex_term_binary_slice(binary: i64, start: i64) i64 {
    if (word_tag(binary) != tag_binary) return nil_word;
    const len = binary_len(binary);
    if (start < 0 or start > @as(i64, @intCast(len))) return nil_word;
    const rest_len = len - @as(usize, @intCast(start));
    const slice = alloc_words(rest_len + 1) orelse return nil_word;
    slice[0] = @intCast(rest_len);
    const bytes = binary_bytes(binary);
    var i: usize = 0;
    while (i < rest_len) : (i += 1) {
        slice[i + 1] = bytes[@as(usize, @intCast(start)) + i];
    }
    return word_from_ptr(slice, tag_binary);
}

const Utf8Decoded = struct { cp: i64, width: i64 };

fn utf8_at(binary: i64, index: i64) ?Utf8Decoded {
    if (word_tag(binary) != tag_binary) return null;
    const len = binary_len(binary);
    if (index < 0 or index >= @as(i64, @intCast(len))) return null;
    const bytes = binary_bytes(binary);
    const start: usize = @intCast(index);

    const b0: u8 = @intCast(bytes[start] & 0xFF);
    if (b0 < 0x80) {
        return .{ .cp = b0, .width = 1 };
    } else if (b0 >= 0xC2 and b0 <= 0xDF) {
        if (start + 1 >= len) return null;
        const b1: u8 = @intCast(bytes[start + 1] & 0xFF);
        if (b1 & 0xC0 != 0x80) return null;
        return .{ .cp = (@as(i64, b0 & 0x1F) << 6) | @as(i64, b1 & 0x3F), .width = 2 };
    } else if (b0 >= 0xE0 and b0 <= 0xEF) {
        if (start + 2 >= len) return null;
        const b1: u8 = @intCast(bytes[start + 1] & 0xFF);
        const b2: u8 = @intCast(bytes[start + 2] & 0xFF);
        if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80) return null;
        if (b0 == 0xE0 and b1 < 0xA0) return null;
        if (b0 == 0xED and b1 >= 0xA0) return null;
        return .{
            .cp = (@as(i64, b0 & 0x0F) << 12) | (@as(i64, b1 & 0x3F) << 6) | @as(i64, b2 & 0x3F),
            .width = 3,
        };
    } else if (b0 >= 0xF0 and b0 <= 0xF4) {
        if (start + 3 >= len) return null;
        const b1: u8 = @intCast(bytes[start + 1] & 0xFF);
        const b2: u8 = @intCast(bytes[start + 2] & 0xFF);
        const b3: u8 = @intCast(bytes[start + 3] & 0xFF);
        if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80 or b3 & 0xC0 != 0x80) return null;
        if (b0 == 0xF0 and b1 < 0x90) return null;
        if (b0 == 0xF4 and b1 > 0x8F) return null;
        return .{
            .cp = (@as(i64, b0 & 0x07) << 18) | (@as(i64, b1 & 0x3F) << 12) |
                (@as(i64, b2 & 0x3F) << 6) | @as(i64, b3 & 0x3F),
            .width = 4,
        };
    }
    return null;
}

/// Decodes the UTF-8 codepoint at `index` as a tagged int term; nil for
/// invalid sequences or out-of-range.
pub export fn ex_term_binary_utf8_get(binary: i64, index: i64) i64 {
    const decoded = utf8_at(binary, index) orelse return nil_word;
    return decoded.cp << @intCast(tag_shift);
}

/// Returns the byte width of the UTF-8 codepoint at `index`; 0 for invalid
/// sequences or out-of-range.
pub export fn ex_term_binary_utf8_width(binary: i64, index: i64) i64 {
    const decoded = utf8_at(binary, index) orelse return 0;
    return decoded.width;
}

/// Number of UTF-8 codepoints in a binary; invalid sequences count as one
/// byte each. 0 for non-binaries.
pub export fn ex_term_binary_utf8_length(binary: i64) i64 {
    if (word_tag(binary) != tag_binary) return 0;
    const len: i64 = @intCast(binary_len(binary));
    var count: i64 = 0;
    var i: i64 = 0;
    while (i < len) {
        if (utf8_at(binary, i)) |decoded| {
            i += decoded.width;
        } else {
            i += 1;
        }
        count += 1;
    }
    return count;
}

/// Encodes the bytes of a binary as an uppercase hexadecimal binary; nil for
/// non-binaries.
pub export fn ex_term_binary_encode16(binary: i64) i64 {
    if (word_tag(binary) != tag_binary) return nil_word;
    const len = binary_len(binary);
    const out_len = len * 2;
    const words = alloc_words(out_len + 1) orelse return nil_word;
    words[0] = @intCast(out_len);
    const bytes = binary_bytes(binary);
    const hex = "0123456789ABCDEF";
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const b: u8 = @intCast(bytes[i] & 0xFF);
        words[i * 2 + 1] = @intCast(hex[b >> 4]);
        words[i * 2 + 2] = @intCast(hex[b & 0x0F]);
    }
    return word_from_ptr(words, tag_binary);
}

fn hex_value(byte: i64) i8 {
    const b: u8 = @intCast(byte & 0xFF);
    if (b >= '0' and b <= '9') return @intCast(b - '0');
    if (b >= 'A' and b <= 'F') return @intCast(b - 'A' + 10);
    return -1;
}

/// Decodes an uppercase hexadecimal binary into a byte binary; nil for
/// non-binaries, odd lengths, or invalid digits.
pub export fn ex_term_binary_decode16(binary: i64) i64 {
    if (word_tag(binary) != tag_binary) return nil_word;
    const len = binary_len(binary);
    if (len % 2 != 0) return nil_word;
    const out_len = len / 2;
    const words = alloc_words(out_len + 1) orelse return nil_word;
    words[0] = @intCast(out_len);
    const bytes = binary_bytes(binary);
    var i: usize = 0;
    while (i < len) : (i += 2) {
        const hi = hex_value(bytes[i]);
        const lo = hex_value(bytes[i + 1]);
        if (hi < 0 or lo < 0) return nil_word;
        words[i / 2 + 1] = @as(i64, hi) << 4 | lo;
    }
    return word_from_ptr(words, tag_binary);
}

/// Renders a tagged integer term as a decimal binary; nil for non-integers.
pub export fn ex_term_int_to_string(word: i64) i64 {
    if (!is_int(word)) return nil_word;
    const value = word_payload(word);
    var digits: [24]u8 = undefined;
    var i: usize = 0;
    const negative = value < 0;
    var mag: u64 = @abs(value);
    if (mag == 0) {
        digits[0] = '0';
        i = 1;
    } else {
        while (mag > 0) : (mag /= 10) {
            digits[i] = @intCast('0' + mag % 10);
            i += 1;
        }
    }
    if (negative) {
        digits[i] = '-';
        i += 1;
    }
    const words = alloc_words(i + 1) orelse return nil_word;
    words[0] = @intCast(i);
    var j: usize = 0;
    while (j < i) : (j += 1) {
        words[j + 1] = digits[i - 1 - j];
    }
    return word_from_ptr(words, tag_binary);
}

/// Parses a decimal binary (optionally signed) into a scalar i64; 0 for
/// non-binaries, empty or invalid strings, or i64 overflow.
pub export fn ex_term_string_to_int(binary: i64) i64 {
    if (word_tag(binary) != tag_binary) return 0;
    const len = binary_len(binary);
    if (len == 0) return 0;
    const bytes = binary_bytes(binary);
    var i: usize = 0;
    var negative = false;
    if (bytes[0] == '-') {
        negative = true;
        i = 1;
        if (len == 1) return 0;
    }
    var value: i64 = 0;
    while (i < len) : (i += 1) {
        const b: u8 = @intCast(bytes[i] & 0xFF);
        if (b < '0' or b > '9') return 0;
        const digit: i64 = b - '0';
        if (value > @divTrunc(std.math.maxInt(i64) - digit, 10)) return 0;
        value = value * 10 + digit;
    }
    return if (negative) -value else value;
}

/// Converts a flat key/value list word (even length) into a map word.
pub export fn ex_term_map_from_list(list: i64) i64 {
    const count = list_len(list);
    if (count % 2 != 0) return nil_word;
    const map = alloc_words(1 + count) orelse return nil_word;
    map[0] = @intCast(count / 2);
    copy_list_into(map[1 .. count + 1], list);
    return word_from_ptr(map, tag_map);
}

/// Converts a list of integer byte words into a binary word.
pub export fn ex_term_binary_from_list(list: i64) i64 {
    const len = list_len(list);
    const binary = alloc_words(len + 1) orelse return nil_word;
    binary[0] = @intCast(len);

    var current = list;
    var i: usize = 0;
    while (word_tag(current) == tag_list) {
        const cell: *[2]i64 = @ptrFromInt(@as(usize, @bitCast(current)) & ~tag_mask);
        const byte = if (is_int(cell[0])) word_payload(cell[0]) & 0xFF else 0;
        binary[i + 1] = byte;
        i += 1;
        current = cell[1];
    }

    return word_from_ptr(binary, tag_binary);
}

pub export fn ex_term_is_integer(word: i64) i64 {
    return if (is_int(word)) 1 else 0;
}

pub export fn ex_term_is_atom(word: i64) i64 {
    return if (is_atom(word)) 1 else 0;
}

pub export fn ex_term_is_binary(word: i64) i64 {
    return if (word_tag(word) == tag_binary) 1 else 0;
}

pub export fn ex_term_is_list(word: i64) i64 {
    return if (is_list_word(word)) 1 else 0;
}

pub export fn ex_term_is_tuple(word: i64) i64 {
    return if (word_tag(word) == tag_tuple) 1 else 0;
}

pub export fn ex_term_is_map(word: i64) i64 {
    return if (word_tag(word) == tag_map) 1 else 0;
}

// The declaration-first manifest uses dotted symbol names (`ex.term.*`); Zig
// identifiers cannot contain dots, so the C ABI symbols are re-exported under
// the manifest names.
comptime {
    @export(&ex_term_self, .{ .name = "ex.term.self" });
    @export(&ex_term_send, .{ .name = "ex.term.send" });
    @export(&ex_term_receive, .{ .name = "ex.term.receive" });
    @export(&ex_term_mailbox_clear, .{ .name = "ex.term.mailbox_clear" });
    @export(&ex_term_to_int, .{ .name = "ex.term.to_int" });
    @export(&ex_term_jmp_buf_size, .{ .name = "ex.term.jmp_buf_size" });
    @export(&ex_term_setjmp_addr, .{ .name = "ex.term.setjmp_addr" });
    @export(&ex_term_try_push, .{ .name = "ex.term.try_push" });
    @export(&ex_term_try_pop, .{ .name = "ex.term.try_pop" });
    @export(&ex_term_throw, .{ .name = "ex.term.throw" });
    @export(&ex_term_catch_value, .{ .name = "ex.term.catch_value" });
    @export(&ex_term_make_fun, .{ .name = "ex.term.make_fun" });
    @export(&ex_term_fun_idx, .{ .name = "ex.term.fun_idx" });
    @export(&ex_term_fun_env, .{ .name = "ex.term.fun_env" });
    @export(&ex_term_list_cons, .{ .name = "ex.term.list_cons" });
    @export(&ex_term_tuple_from_list, .{ .name = "ex.term.tuple_from_list" });
    @export(&ex_term_tuple_get, .{ .name = "ex.term.tuple_get" });
    @export(&ex_term_tuple_length, .{ .name = "ex.term.tuple_length" });
    @export(&ex_term_map_length, .{ .name = "ex.term.map_length" });
    @export(&ex_term_enumerable_count, .{ .name = "ex.term.enumerable_count" });
    @export(&ex_term_enumerable_to_list, .{ .name = "ex.term.enumerable_to_list" });
    @export(&ex_term_enumerable_to_list_range, .{ .name = "ex.term.enumerable_to_list_range" });
    @export(&ex_term_enumerable_reduce, .{ .name = "ex.term.enumerable_reduce" });
    @export(&ex_term_enumerable_reduce_c, .{ .name = "ex.term.enumerable_reduce_c" });
    @export(&ex_term_enumerable_reduce_range, .{ .name = "ex.term.enumerable_reduce_range" });
    @export(&ex_term_enumerable_reduce_fun, .{ .name = "ex.term.enumerable_reduce_fun" });
    @export(&ex_term_register_callback, .{ .name = "ex.term.register_callback" });
    @export(&ex_term_call_callback, .{ .name = "ex.term.call_callback" });
    @export(&ex_term_list_head, .{ .name = "ex.term.list_head" });
    @export(&ex_term_list_tail, .{ .name = "ex.term.list_tail" });
    @export(&ex_term_list_get, .{ .name = "ex.term.list_get" });
    @export(&ex_term_list_length, .{ .name = "ex.term.list_length" });
    @export(&ex_term_eq, .{ .name = "ex.term.eq" });
    @export(&ex_term_binary_length, .{ .name = "ex.term.binary_length" });
    @export(&ex_term_binary_get, .{ .name = "ex.term.binary_get" });
    @export(&ex_term_binary_slice, .{ .name = "ex.term.binary_slice" });
    @export(&ex_term_binary_utf8_get, .{ .name = "ex.term.binary_utf8_get" });
    @export(&ex_term_binary_utf8_width, .{ .name = "ex.term.binary_utf8_width" });
    @export(&ex_term_binary_utf8_length, .{ .name = "ex.term.binary_utf8_length" });
    @export(&ex_term_binary_encode16, .{ .name = "ex.term.binary_encode16" });
    @export(&ex_term_binary_decode16, .{ .name = "ex.term.binary_decode16" });
    @export(&ex_term_int_to_string, .{ .name = "ex.term.int_to_string" });
    @export(&ex_term_string_to_int, .{ .name = "ex.term.string_to_int" });
    @export(&ex_term_map_from_list, .{ .name = "ex.term.map_from_list" });
    @export(&ex_term_binary_from_list, .{ .name = "ex.term.binary_from_list" });
    @export(&ex_term_is_integer, .{ .name = "ex.term.is_integer" });
    @export(&ex_term_is_atom, .{ .name = "ex.term.is_atom" });
    @export(&ex_term_is_binary, .{ .name = "ex.term.is_binary" });
    @export(&ex_term_is_list, .{ .name = "ex.term.is_list" });
    @export(&ex_term_is_tuple, .{ .name = "ex.term.is_tuple" });
    @export(&ex_term_is_map, .{ .name = "ex.term.is_map" });
}

test "term ABI tag and word layout" {
    // 1 << 3 = 8 is an immediate integer term.
    const one: i64 = 8;
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_integer(one));
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_atom(one));
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_tuple(one));

    // nil is both the empty list and an atom.
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_atom(nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_list(nil_word));
}

test "term ABI construction and predicates" {
    const one: i64 = 8;
    const two: i64 = 16;
    const three: i64 = 24;

    // [1, 2] via cons chain.
    const list = ex_term_list_cons(one, ex_term_list_cons(two, nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_list(list));
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_tuple(list));

    // {1, 2} from list.
    const tuple = ex_term_tuple_from_list(list);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_tuple(tuple));
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_list(tuple));

    // %{1 => 2} from a flat key/value list.
    const entries = ex_term_list_cons(one, ex_term_list_cons(two, nil_word));
    const map = ex_term_map_from_list(entries);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_map(map));
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_tuple(map));

    // <<1, 2, 3>> from a byte list.
    const bytes = ex_term_list_cons(one, ex_term_list_cons(two, ex_term_list_cons(three, nil_word)));
    const binary = ex_term_binary_from_list(bytes);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_binary(binary));
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_map(binary));

    // UTF-8 length: "aé中" is 3 codepoints / 6 bytes.
    const utf8_bytes = ex_term_list_cons(97 << @intCast(tag_shift), ex_term_list_cons(0xC3 << @intCast(tag_shift), ex_term_list_cons(0xA9 << @intCast(tag_shift), ex_term_list_cons(0xE4 << @intCast(tag_shift), ex_term_list_cons(0xB8 << @intCast(tag_shift), ex_term_list_cons(0xAD << @intCast(tag_shift), nil_word))))));
    const utf8_bin = ex_term_binary_from_list(utf8_bytes);
    try std.testing.expectEqual(@as(i64, 6), ex_term_binary_length(utf8_bin));
    try std.testing.expectEqual(@as(i64, 3), ex_term_binary_utf8_length(utf8_bin));

    // Base16 round-trip: <<0xAB, 0xCD>> -> "ABCD" -> <<0xAB, 0xCD>>
    const hex_src = ex_term_list_cons(0xAB << @intCast(tag_shift), ex_term_list_cons(0xCD << @intCast(tag_shift), nil_word));
    const hex_bin = ex_term_binary_from_list(hex_src);
    const encoded = ex_term_binary_encode16(hex_bin);
    try std.testing.expectEqual(@as(i64, 4), ex_term_binary_length(encoded));
    const enc_bytes = binary_bytes(encoded);
    try std.testing.expectEqual(@as(i64, 'A'), enc_bytes[0]);
    try std.testing.expectEqual(@as(i64, 'B'), enc_bytes[1]);
    try std.testing.expectEqual(@as(i64, 'C'), enc_bytes[2]);
    try std.testing.expectEqual(@as(i64, 'D'), enc_bytes[3]);
    const decoded = ex_term_binary_decode16(encoded);
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(decoded, hex_bin));
    const odd_hex = ex_term_binary_from_list(ex_term_list_cons(65 << @intCast(tag_shift), nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_binary_decode16(odd_hex)));

    // Integer <-> decimal string round-trip.
    const forty_two: i64 = 42 << @intCast(tag_shift);
    const num_str = ex_term_int_to_string(forty_two);
    try std.testing.expectEqual(@as(i64, 2), ex_term_binary_length(num_str));
    try std.testing.expectEqual(@as(i64, '4'), binary_bytes(num_str)[0]);
    try std.testing.expectEqual(@as(i64, '2'), binary_bytes(num_str)[1]);
    try std.testing.expectEqual(@as(i64, 42), ex_term_string_to_int(num_str));
    const neg_str = ex_term_int_to_string(-1 << @intCast(tag_shift));
    try std.testing.expectEqual(@as(i64, 2), ex_term_binary_length(neg_str));
    try std.testing.expectEqual(@as(i64, -1), ex_term_string_to_int(neg_str));
}

test "term ABI reads" {
    const one: i64 = 8;
    const two: i64 = 16;

    // tuple reads
    const tuple = ex_term_tuple_from_list(ex_term_list_cons(one, ex_term_list_cons(two, nil_word)));
    try std.testing.expectEqual(@as(i64, 2), ex_term_tuple_length(tuple));
    try std.testing.expectEqual(one, ex_term_tuple_get(tuple, 0));
    try std.testing.expectEqual(two, ex_term_tuple_get(tuple, 1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_tuple_get(tuple, 2)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_tuple_get(one, 0)));

    // list reads
    const list = ex_term_list_cons(one, ex_term_list_cons(two, nil_word));
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(list));
    try std.testing.expectEqual(one, ex_term_list_head(list));
    try std.testing.expectEqual(two, ex_term_list_head(ex_term_list_tail(list)));
    try std.testing.expectEqual(one, ex_term_list_get(list, 0));
    try std.testing.expectEqual(two, ex_term_list_get(list, 1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_list_get(list, 2)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_list(ex_term_list_tail(ex_term_list_tail(list))));
    try std.testing.expectEqual(@as(i64, 0), ex_term_list_length(nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_list_head(nil_word)));

    // map reads
    const entries = ex_term_list_cons(one, ex_term_list_cons(two, nil_word));
    const map = ex_term_map_from_list(entries);
    try std.testing.expectEqual(@as(i64, 1), ex_term_map_length(map));
    try std.testing.expectEqual(@as(i64, 0), ex_term_map_length(one));

    // enumerable counts: list length, tuple arity, map pairs, binary bytes
    const count_bytes = ex_term_list_cons(one, ex_term_list_cons(two, ex_term_list_cons(one, nil_word)));
    const count_bin = ex_term_binary_from_list(count_bytes);
    try std.testing.expectEqual(@as(i64, 2), ex_term_enumerable_count(list));
    try std.testing.expectEqual(@as(i64, 2), ex_term_enumerable_count(tuple));
    try std.testing.expectEqual(@as(i64, 1), ex_term_enumerable_count(map));
    try std.testing.expectEqual(@as(i64, 3), ex_term_enumerable_count(count_bin));
    try std.testing.expectEqual(@as(i64, 0), ex_term_enumerable_count(one));

    // enumerable to_list: list identity, tuple elements, map pairs, binary bytes
    try std.testing.expectEqual(list, ex_term_enumerable_to_list(list));
    const tuple_list = ex_term_enumerable_to_list(tuple);
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(tuple_list));
    try std.testing.expectEqual(one, ex_term_list_head(tuple_list));
    const to_list_bytes = ex_term_enumerable_to_list(count_bin);
    try std.testing.expectEqual(@as(i64, 3), ex_term_list_length(to_list_bytes));
    try std.testing.expectEqual(two, ex_term_list_head(ex_term_list_tail(to_list_bytes)));
    try std.testing.expectEqual(@as(i64, 3), ex_term_list_length(ex_term_enumerable_to_list_range(1, 3)));
    try std.testing.expectEqual(@as(i64, 3), ex_term_list_length(ex_term_enumerable_to_list_range(3, 1)));

    // enumerable reduce by tag: sum over list/tuple/binary
    try std.testing.expectEqual(@as(i64, 3), ex_term_enumerable_reduce(list, 0, 1));
    try std.testing.expectEqual(@as(i64, 3), ex_term_enumerable_reduce(tuple, 0, 1));
    try std.testing.expectEqual(@as(i64, 4), ex_term_enumerable_reduce(count_bin, 0, 1));
    try std.testing.expectEqual(@as(i64, 7), ex_term_enumerable_reduce(list, 4, 1));
    try std.testing.expectEqual(@as(i64, 4), ex_term_enumerable_reduce(list, 4, 2));
    try std.testing.expectEqual(@as(i64, 0), ex_term_enumerable_reduce(one, 0, 1));
    const pair_entries = ex_term_list_cons(one, ex_term_list_cons(two, ex_term_list_cons(one, ex_term_list_cons(two, nil_word))));
    const pair_map = ex_term_map_from_list(pair_entries);
    try std.testing.expectEqual(@as(i64, 4), ex_term_enumerable_reduce(pair_map, 0, 3));
    try std.testing.expectEqual(@as(i64, 10), ex_term_enumerable_reduce(pair_map, 6, 3));
    try std.testing.expectEqual(@as(i64, 2), ex_term_enumerable_reduce(pair_map, 0, 4));
    try std.testing.expectEqual(@as(i64, 8), ex_term_enumerable_reduce(pair_map, 6, 4));
    try std.testing.expectEqual(@as(i64, 6), ex_term_enumerable_reduce(pair_map, 0, 5));
    try std.testing.expectEqual(@as(i64, 12), ex_term_enumerable_reduce(pair_map, 6, 5));
    const pair_map_list = ex_term_enumerable_to_list(pair_map);
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(pair_map_list));
    const first_pair = ex_term_list_head(pair_map_list);
    try std.testing.expectEqual(@as(i64, 2), ex_term_tuple_length(first_pair));
    try std.testing.expectEqual(@as(i64, 2), ex_term_enumerable_reduce(list, 1, 6));
    try std.testing.expectEqual(@as(i64, 2), ex_term_enumerable_reduce(tuple, 1, 6));
    try std.testing.expectEqual(@as(i64, 2), ex_term_enumerable_reduce(count_bin, 1, 6));
    try std.testing.expectEqual(@as(i64, 8), ex_term_enumerable_reduce(list, 4, 6));
    try std.testing.expectEqual(@as(i64, 7), ex_term_enumerable_reduce(list, 10, 7));
    try std.testing.expectEqual(@as(i64, 11), ex_term_enumerable_reduce(list, 10, 8));
    try std.testing.expectEqual(@as(i64, 5), ex_term_enumerable_reduce(list, 10, 9));
    try std.testing.expectEqual(@as(i64, 0), ex_term_enumerable_reduce(list, 10, 10));
    try std.testing.expectEqual(@as(i64, 0), ex_term_enumerable_reduce(list, 10, 11));
    try std.testing.expectEqual(@as(i64, 0), ex_term_enumerable_reduce(list, 10, 12));
    try std.testing.expectEqual(@as(i64, 23), ex_term_enumerable_reduce_c(list, 0, 13, 10));
    try std.testing.expectEqual(@as(i64, 26), ex_term_enumerable_reduce_c(tuple, 3, 13, 10));
    try std.testing.expectEqual(@as(i64, 30), ex_term_enumerable_reduce_c(list, 0, 14, 10));
    try std.testing.expectEqual(@as(i64, 6), ex_term_enumerable_reduce_range(1, 3, 0, 1));
    try std.testing.expectEqual(@as(i64, 6), ex_term_enumerable_reduce_range(3, 1, 0, 1));
    try std.testing.expectEqual(@as(i64, 6), ex_term_enumerable_reduce_range(1, 3, 1, 6));
    try std.testing.expectEqual(@as(i64, 3), ex_term_enumerable_reduce_range(1, 3, 0, 15));
    try std.testing.expectEqual(@as(i64, 3), ex_term_enumerable_reduce_range(3, 1, 0, 15));
    try std.testing.expectEqual(
        @as(i64, 3),
        ex_term_enumerable_reduce_fun(list, 0, &test_reducer_sum),
    );
    try std.testing.expectEqual(
        @as(i64, 11),
        ex_term_enumerable_reduce_fun(tuple, 8, &test_reducer_sum),
    );
    try std.testing.expectEqual(@as(i64, -1), ex_term_call_callback(0, 1));
    try std.testing.expectEqual(
        @as(i64, 0),
        ex_term_register_callback(0, &test_callback),
    );
    try std.testing.expectEqual(@as(i64, 42), ex_term_call_callback(0, 10));

    // word equality
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(one, one));
    try std.testing.expectEqual(@as(i64, 0), ex_term_eq(one, two));

    // deep equality: structurally equal containers built separately are equal
    const tuple_a = ex_term_tuple_from_list(ex_term_list_cons(one, ex_term_list_cons(two, nil_word)));
    const tuple_b = ex_term_tuple_from_list(ex_term_list_cons(one, ex_term_list_cons(two, nil_word)));
    const tuple_c = ex_term_tuple_from_list(ex_term_list_cons(one, nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(tuple_a, tuple_b));
    try std.testing.expectEqual(@as(i64, 0), ex_term_eq(tuple_a, tuple_c));

    const list_a = ex_term_list_cons(one, ex_term_list_cons(two, nil_word));
    const list_b = ex_term_list_cons(one, ex_term_list_cons(two, nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(list_a, list_b));
    try std.testing.expectEqual(@as(i64, 0), ex_term_eq(list_a, tuple_a));

    // binary reads
    const byte_list = ex_term_list_cons(one, ex_term_list_cons(two, nil_word));
    const binary = ex_term_binary_from_list(byte_list);
    try std.testing.expectEqual(@as(i64, 2), ex_term_binary_length(binary));
    try std.testing.expectEqual(one, ex_term_binary_get(binary, 0));
    try std.testing.expectEqual(two, ex_term_binary_get(binary, 1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_binary_get(binary, 2)));
    try std.testing.expectEqual(@as(i64, 0), ex_term_binary_length(one));

    const rest = ex_term_binary_slice(binary, 1);
    try std.testing.expectEqual(@as(i64, 1), ex_term_binary_length(rest));
    try std.testing.expectEqual(two, ex_term_binary_get(rest, 0));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_binary_slice(binary, 3)));

    // deep binary equality
    const bin_b = ex_term_binary_from_list(byte_list);
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(binary, bin_b));

    // utf8 reads: é = 0xC3 0xA9 -> codepoint 233, width 2
    const e_binary = ex_term_binary_from_list(ex_term_list_cons(@as(i64, 195 << 3), ex_term_list_cons(@as(i64, 169 << 3), nil_word)));
    try std.testing.expectEqual(@as(i64, 2), ex_term_binary_utf8_width(e_binary, 0));
    try std.testing.expectEqual(@as(i64, 233 << 3), ex_term_binary_utf8_get(e_binary, 0));

    const ascii = ex_term_binary_from_list(ex_term_list_cons(@as(i64, 65 << 3), nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_binary_utf8_width(ascii, 0));
    try std.testing.expectEqual(@as(i64, 65 << 3), ex_term_binary_utf8_get(ascii, 0));

    // truncated and overlong sequences are invalid
    const truncated = ex_term_binary_from_list(ex_term_list_cons(@as(i64, 195 << 3), nil_word));
    try std.testing.expectEqual(@as(i64, 0), ex_term_binary_utf8_width(truncated, 0));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_binary_utf8_get(truncated, 0)));
}

fn test_reducer_sum(item: i64, acc: i64) callconv(.c) i64 {
    return acc + item;
}

fn test_callback(arg: i64) callconv(.c) i64 {
    return arg + 32;
}

test "term ABI mailbox and integer untag" {
    const one: i64 = 1 << @intCast(tag_shift);
    const two: i64 = 2 << @intCast(tag_shift);

    // empty mailbox receives nil
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_receive()));

    // self() is the pid of the single actor
    const pid = ex_term_self();
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_atom(pid));

    // send enqueues in FIFO order and returns the message
    try std.testing.expectEqual(one, ex_term_send(pid, one));
    try std.testing.expectEqual(two, ex_term_send(pid, two));
    try std.testing.expectEqual(one, ex_term_receive());
    try std.testing.expectEqual(two, ex_term_receive());
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_receive()));

    // integer untag
    try std.testing.expectEqual(@as(i64, 1), ex_term_to_int(one));
    try std.testing.expectEqual(@as(i64, 2), ex_term_to_int(two));
    try std.testing.expectEqual(@as(i64, 0), ex_term_to_int(ex_term_self()));
}

test "term ABI throw unwinds to the innermost try" {
    var buf: c.jmp_buf = undefined;
    try std.testing.expectEqual(@as(i64, 0), ex_term_try_push(&buf));

    if (c.setjmp(&buf) == 0) {
        // Normal path: throw longjmps back to the setjmp above.
        ex_term_throw(42 << @intCast(tag_shift));
        unreachable;
    } else {
        try std.testing.expectEqual(@as(i64, 42 << @intCast(tag_shift)), ex_term_catch_value());
    }

    try std.testing.expectEqual(@as(i64, 0), ex_term_try_pop());

    // jmp_buf size is positive and matches the C ABI
    try std.testing.expect(ex_term_jmp_buf_size() > 0);
}

fn ex_term_is_nil_word(word: i64) i64 {
    return if (word == nil_word) 1 else 0;
}
