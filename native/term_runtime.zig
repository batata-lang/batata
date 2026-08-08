//! Zig term runtime for the `ex` dialect.
//!
//! Implements the declaration-first ABI in `native/ABI.md`. All exported
//! symbols are C ABI functions over 64-bit tagged words; Beaver's ex
//! conversion plan emits calls to exactly these symbols.

const std = @import("std");

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
    @export(&ex_term_make_fun, .{ .name = "ex.term.make_fun" });
    @export(&ex_term_fun_idx, .{ .name = "ex.term.fun_idx" });
    @export(&ex_term_fun_env, .{ .name = "ex.term.fun_env" });
    @export(&ex_term_list_cons, .{ .name = "ex.term.list_cons" });
    @export(&ex_term_tuple_from_list, .{ .name = "ex.term.tuple_from_list" });
    @export(&ex_term_tuple_get, .{ .name = "ex.term.tuple_get" });
    @export(&ex_term_tuple_length, .{ .name = "ex.term.tuple_length" });
    @export(&ex_term_list_head, .{ .name = "ex.term.list_head" });
    @export(&ex_term_list_tail, .{ .name = "ex.term.list_tail" });
    @export(&ex_term_list_length, .{ .name = "ex.term.list_length" });
    @export(&ex_term_eq, .{ .name = "ex.term.eq" });
    @export(&ex_term_binary_length, .{ .name = "ex.term.binary_length" });
    @export(&ex_term_binary_get, .{ .name = "ex.term.binary_get" });
    @export(&ex_term_binary_slice, .{ .name = "ex.term.binary_slice" });
    @export(&ex_term_binary_utf8_get, .{ .name = "ex.term.binary_utf8_get" });
    @export(&ex_term_binary_utf8_width, .{ .name = "ex.term.binary_utf8_width" });
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
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_list(ex_term_list_tail(ex_term_list_tail(list))));
    try std.testing.expectEqual(@as(i64, 0), ex_term_list_length(nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_list_head(nil_word)));

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

fn ex_term_is_nil_word(word: i64) i64 {
    return if (word == nil_word) 1 else 0;
}
