//! Zig term runtime for the `ex` dialect.
//!
//! Implements the declaration-first ABI in `native/ABI.md`. All exported
//! symbols are C ABI functions over 64-bit tagged words; Beaver's ex
//! conversion plan emits calls to exactly these symbols.

const std = @import("std");
const c = @cImport({
    @cInclude("setjmp.h");
    @cInclude("stdio.h");
    @cInclude("time.h");
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
//   binary: [len: i64] [packed byte: u8 ... len] [alignment padding]
//   list:   cons cells [head: i64] [tail: i64]
//   fun:    [fn_idx: i64] [env_len: i64] [env: i64 ... env_len]

// Runtime instances own execution state. The compatibility path lazily binds
// one instance per OS thread; explicit handles let future actor workers enter
// the same execution without returning to process-global mutable storage.
const arena_chunk_words = 64 * 1024;
// The initial segmented-arena policy deliberately permits growth beyond the
// former 32 MiB heap without making long-running bump allocation unbounded.
const arena_chunk_cap = 128;
const arena_owner_unassigned = std.math.maxInt(u32);

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

fn binary_bytes(binary: i64) [*]u8 {
    return @ptrFromInt((@as(usize, @bitCast(binary)) & ~tag_mask) + @sizeOf(i64));
}

fn alloc_binary(len: usize) ?[*]i64 {
    const payload_words = (len + @sizeOf(i64) - 1) / @sizeOf(i64);
    const words = alloc_words(payload_words + 1) orelse return null;
    words[0] = @intCast(len);
    return words;
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

// Actor scheduling model (#35): a single process with a FIFO mailbox and a
// reduction clock. `Clock.used` is charged by `ex.term.clock_tick` before
// effectful steps / loop back-edges; when it exceeds `budget` the compiled
// code yields. `epoch` is a continuation-generation counter: message arrival
// or a scheduler round bumps it, invalidating stale resume tokens.
const mailbox_cap: usize = 64;

const RuntimeMutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *RuntimeMutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *RuntimeMutex) void {
        self.state.unlock();
    }
};

const Clock = struct {
    budget: i64,
    used: i64,
    epoch: i64,
};

const SignalKind = enum(u8) { message, exit, down };

const Signal = struct {
    kind: SignalKind,
    sender: i64,
    payload: i64,
    sequence: u64,
};

// Every delivery enters one ordered per-process signal queue. Receives expose
// only message payloads for now; exit and DOWN signals use the same envelope
// in the next supervision layer.
const Mailbox = struct {
    lock: RuntimeMutex = .{},
    queue: [mailbox_cap]Signal = undefined,
    head: usize = 0,
    len: usize = 0,
    next_sequence: u64 = 0,

    fn pushSignal(self: *Mailbox, kind: SignalKind, sender: i64, payload: i64) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.len >= mailbox_cap) return false;
        const index = (self.head + self.len) % mailbox_cap;
        self.queue[index] = .{
            .kind = kind,
            .sender = sender,
            .payload = payload,
            .sequence = self.next_sequence,
        };
        self.next_sequence +%= 1;
        self.len += 1;
        return true;
    }

    fn push(self: *Mailbox, sender: i64, msg: i64) bool {
        return self.pushSignal(.message, sender, msg);
    }

    fn pop(self: *Mailbox) ?i64 {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.len == 0) return null;
        const msg = self.queue[self.head].payload;
        self.head = (self.head + 1) % mailbox_cap;
        self.len -= 1;
        return msg;
    }

    fn clear(self: *Mailbox) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.head = 0;
        self.len = 0;
    }

    fn count(self: *Mailbox) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return self.len;
    }

    fn peek(self: *Mailbox, cursor: usize) ?i64 {
        self.lock.lock();
        defer self.lock.unlock();
        if (cursor >= self.len) return null;
        return self.queue[(self.head + cursor) % mailbox_cap].payload;
    }

    fn peekSignal(self: *Mailbox, cursor: usize) ?Signal {
        self.lock.lock();
        defer self.lock.unlock();
        if (cursor >= self.len) return null;
        return self.queue[(self.head + cursor) % mailbox_cap];
    }

    fn remove(self: *Mailbox, cursor: usize) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (cursor >= self.len) return false;
        var i = cursor;
        while (i + 1 < self.len) : (i += 1) {
            const to = (self.head + i) % mailbox_cap;
            const from = (self.head + i + 1) % mailbox_cap;
            self.queue[to] = self.queue[from];
        }
        self.len -= 1;
        return true;
    }
};

const ProcessStatus = enum(u8) { runnable, waiting, done, exited };
const relation_cap: usize = 32;

const Link = struct {
    peer: i64,
    exit_tag: i64,
    normal_tag: i64,
};

const Monitor = struct {
    watcher: i64,
    reference: i64,
    down_tag: i64,
    process_tag: i64,
    normal_tag: i64,
};

// Preemptive scheduler continuation (#35 slice 5): a budgeted cursor loop
// saves its (arg, acc, cursor) state here before yielding. The scheduler
// driver resumes the process by re-invoking its entry, which restores the
// state when `pending` is set and the epoch matches. An explicit
// `clock_bump_epoch` invalidates the continuation (the entry restarts), the
// hook a future selective-receive slice uses to force mailbox re-evaluation.
const Continuation = struct {
    active: bool = false,
    epoch: i64 = 0,
    arg: i64 = 0,
    acc: i64 = 0,
    cursor: i64 = 0,
    // Receive-type continuations (selective-receive mailbox scans) are
    // invalidated by message arrival, so the scan restarts and observes the
    // new message; loop-type continuations (pure cursor loops) are not.
    receive: bool = false,
};

const Process = struct {
    state_lock: RuntimeMutex = .{},
    owner: std.atomic.Value(u32) = .init(0),
    last_worker: std.atomic.Value(u32) = .init(0),
    last_thread_id: std.atomic.Value(usize) = .init(0),
    pid: i64,
    // BEAM-style pid serial (#50 stage 2): recycled slots bump the
    // generation, so a stale pid referencing a recycled slot is rejected.
    generation: u32 = 1,
    mailbox: Mailbox = .{},
    clock: Clock,
    // Closure word of the spawned entry; 0 for the initial process, whose
    // entry is the compiled `__batata_entry` function.
    entry: i64 = 0,
    status: ProcessStatus = .runnable,
    result: i64 = nil_word,
    exit_reason: i64 = nil_word,
    trap_exit: bool = false,
    links: [relation_cap]Link = undefined,
    link_count: usize = 0,
    monitors: [relation_cap]Monitor = undefined,
    monitor_count: usize = 0,
    cont: Continuation = .{},
    // `receive ... after` timeout start (monotonic milliseconds); 0 means the
    // wait loop has not completed its first scan round yet.
    receive_start: i64 = 0,
};

// The process table stores separately allocated Process objects. Growing the
// table moves only pointers: a worker may therefore keep using its actor while
// another worker spawns enough actors to resize the table. In particular,
// atomics and locked mutexes are never memcpy'd or freed during growth.
const default_process_cap: usize = 256;
const max_process_cap: usize = 4096;
const beam_callback_cap = 16;

const ArenaChunk = struct {
    words: ?[]i64 = null,
    bump: usize = 0,
    owner: u32 = arena_owner_unassigned,
};

const Runtime = struct {
    heap_lock: RuntimeMutex = .{},
    scheduler_lock: RuntimeMutex = .{},
    counter_lock: RuntimeMutex = .{},
    callback_lock: RuntimeMutex = .{},
    configured_workers: std.atomic.Value(u32) = .init(1),
    active_actors: std.atomic.Value(u32) = .init(0),
    max_active_actors: std.atomic.Value(u32) = .init(0),
    migrations: std.atomic.Value(u64) = .init(0),
    arena_chunks: [arena_chunk_cap]ArenaChunk = [_]ArenaChunk{.{}} ** arena_chunk_cap,
    arena_chunk_count: usize = 0,
    arena_epoch: u32 = 1,
    processes: []*Process = &.{},
    process_cap: usize = default_process_cap,
    process_count: usize = 0,
    // Free-list of completed process slots (#50 stage 1): `process_done`
    // pushes the slot index, `spawn` pops it first and resets the slot, so a
    // long-running runtime reuses slots instead of growing `process_count`
    // past the concurrency peak. Slot 0 (the per-run entry process) is never
    // recycled.
    free_slots: []usize = &.{},
    free_count: usize = 0,
    claim_cursor: usize = 0,
    processes_initialized: bool = false,
    yield_count: i64 = 0,
    unique_integer_counter: i64 = 0,
    monitor_ref_counter: i64 = 0,
    callbacks: [beam_callback_cap]?*const fn (i64) callconv(.c) i64 =
        [_]?*const fn (i64) callconv(.c) i64{null} ** beam_callback_cap,

    fn deinit(self: *Runtime) void {
        for (self.arena_chunks[0..self.arena_chunk_count]) |chunk| {
            if (chunk.words) |words| std.heap.page_allocator.free(words);
        }
        for (self.processes[0..self.process_count]) |proc| {
            std.heap.page_allocator.destroy(proc);
        }
        if (self.processes.len > 0) std.heap.page_allocator.free(self.processes);
        if (self.free_slots.len > 0) std.heap.page_allocator.free(self.free_slots);
        std.heap.page_allocator.destroy(self);
    }
};

// Host result handles keep an execution runtime alive while a JIT or AOT host
// copies the returned term out of the arena. The generation makes a handle
// deterministic to reject after its slot has been recycled; callers never
// dereference an address supplied by the host.
const result_slot_cap: usize = 4096;

const ResultSlot = struct {
    runtime: ?*Runtime = null,
    word: i64 = 0,
    generation: u32 = 1,
};

var result_lock: RuntimeMutex = .{};
var result_slots: [result_slot_cap]ResultSlot = [_]ResultSlot{.{}} ** result_slot_cap;
var result_cursor: usize = 0;

fn result_handle(index: usize, generation: u32) i64 {
    const bits = (@as(u64, generation) << 32) | @as(u64, @intCast(index + 1));
    return @bitCast(bits);
}

fn result_slot_locked(handle: i64) ?*ResultSlot {
    const bits: u64 = @bitCast(handle);
    const encoded_index: u32 = @truncate(bits);
    if (encoded_index == 0) return null;
    const index = @as(usize, encoded_index - 1);
    if (index >= result_slot_cap) return null;
    const generation: u32 = @truncate(bits >> 32);
    const slot = &result_slots[index];
    if (slot.runtime == null or slot.generation != generation) return null;
    return slot;
}

fn runtime_owns_word(instance: *Runtime, word: i64) bool {
    const tag = word_tag(word);
    if (tag < tag_tuple or tag > tag_fun) return false;
    const address = @as(usize, @bitCast(word)) & ~tag_mask;
    for (instance.arena_chunks[0..instance.arena_chunk_count]) |chunk| {
        const words = chunk.words orelse continue;
        const start = @intFromPtr(words.ptr);
        const end = start + chunk.bump * @sizeOf(i64);
        if (address >= start and address < end) return true;
    }
    return false;
}

fn result_term_kind_locked(slot: *ResultSlot, word: i64) i64 {
    const tag = word_tag(word);
    if (tag == tag_int or tag == tag_atom) return @intCast(tag);
    if (slot.runtime) |instance| {
        if (runtime_owns_word(instance, word)) return @intCast(tag);
    }
    return -1;
}

threadlocal var active_runtime: ?*Runtime = null;
threadlocal var owned_runtime: ?*Runtime = null;
threadlocal var current_process: usize = 0;
// Workers retain the stable Process allocation they claimed. Looking it up
// through the pointer table on every ABI call would still race with growth of
// that table even though the Process itself no longer moves.
threadlocal var current_process_ptr: ?*Process = null;
threadlocal var arena_worker_id: u32 = 0;
threadlocal var arena_cached_runtime: ?*Runtime = null;
threadlocal var arena_cached_epoch: u32 = 0;
threadlocal var arena_cached_chunk: usize = arena_chunk_cap;

fn create_runtime() *Runtime {
    const instance = std.heap.page_allocator.create(Runtime) catch
        @panic("failed to allocate Batata runtime");
    instance.* = .{};
    instance.processes = std.heap.page_allocator.alloc(*Process, instance.process_cap) catch
        @panic("failed to allocate Batata process table");
    instance.free_slots = std.heap.page_allocator.alloc(usize, instance.process_cap) catch
        @panic("failed to allocate Batata process free list");
    return instance;
}

fn runtime() *Runtime {
    if (active_runtime) |instance| return instance;
    if (owned_runtime == null) owned_runtime = create_runtime();
    active_runtime = owned_runtime;
    return active_runtime.?;
}

fn reset_arena(instance: *Runtime) void {
    instance.heap_lock.lock();
    defer instance.heap_lock.unlock();
    for (instance.arena_chunks[0..instance.arena_chunk_count]) |*chunk| {
        chunk.bump = 0;
        chunk.owner = arena_owner_unassigned;
    }
    instance.arena_epoch +%= 1;
    if (instance.arena_epoch == 0) instance.arena_epoch = 1;
}

fn alloc_words(count: usize) ?[*]i64 {
    const instance = runtime();

    if (arena_cached_runtime == instance and
        arena_cached_epoch == instance.arena_epoch and
        arena_cached_chunk < instance.arena_chunk_count)
    {
        const chunk = &instance.arena_chunks[arena_cached_chunk];
        if (chunk.owner == arena_worker_id) {
            const words = chunk.words.?;
            if (chunk.bump + count <= words.len) {
                const start = chunk.bump;
                chunk.bump += count;
                return words[start..][0..count].ptr;
            }
        }
    }

    instance.heap_lock.lock();
    defer instance.heap_lock.unlock();

    var index: usize = 0;
    while (index < instance.arena_chunk_count) : (index += 1) {
        const chunk = &instance.arena_chunks[index];
        const words = chunk.words.?;
        if (chunk.owner == arena_owner_unassigned and count <= words.len) {
            chunk.owner = arena_worker_id;
            chunk.bump = count;
            arena_cached_runtime = instance;
            arena_cached_epoch = instance.arena_epoch;
            arena_cached_chunk = index;
            return words[0..count].ptr;
        }
    }

    if (instance.arena_chunk_count >= arena_chunk_cap) return null;
    const word_count = @max(count, arena_chunk_words);
    const words = std.heap.page_allocator.alloc(i64, word_count) catch return null;
    index = instance.arena_chunk_count;
    instance.arena_chunk_count += 1;
    instance.arena_chunks[index] = .{
        .words = words,
        .bump = count,
        .owner = arena_worker_id,
    };
    arena_cached_runtime = instance;
    arena_cached_epoch = instance.arena_epoch;
    arena_cached_chunk = index;
    return words[0..count].ptr;
}

fn tuple3(a: i64, b: i64, d: i64) i64 {
    const words = alloc_words(4) orelse return nil_word;
    words[0] = 3;
    words[1] = a;
    words[2] = b;
    words[3] = d;
    return word_from_ptr(words, tag_tuple);
}

fn tuple5(a: i64, b: i64, d: i64, e: i64, f: i64) i64 {
    const words = alloc_words(6) orelse return nil_word;
    words[0] = 5;
    words[1] = a;
    words[2] = b;
    words[3] = d;
    words[4] = e;
    words[5] = f;
    return word_from_ptr(words, tag_tuple);
}

/// Allocates an isolated execution instance and returns its opaque handle.
pub export fn ex_term_runtime_create() i64 {
    return @bitCast(@intFromPtr(create_runtime()));
}

/// Binds an execution instance to the calling worker thread.
pub export fn ex_term_runtime_enter(handle: i64) i64 {
    if (handle == 0) return -1;
    active_runtime = @ptrFromInt(@as(usize, @bitCast(handle)));
    current_process = 0;
    current_process_ptr = null;
    return 0;
}

/// Leaves the explicit instance and restores the thread-owned compatibility
/// runtime on the next ABI call.
pub export fn ex_term_runtime_leave() i64 {
    active_runtime = null;
    current_process = 0;
    current_process_ptr = null;
    return 0;
}

/// Releases an execution instance. All workers must leave it before destroy.
pub export fn ex_term_runtime_destroy(handle: i64) i64 {
    if (handle == 0) return -1;
    const instance: *Runtime = @ptrFromInt(@as(usize, @bitCast(handle)));
    if (active_runtime == instance) {
        active_runtime = null;
        current_process_ptr = null;
    }
    if (owned_runtime == instance) owned_runtime = null;
    instance.deinit();
    return 0;
}

/// Pins a completed execution result and transfers ownership of its runtime
/// to the returned opaque handle. Zero means the bounded registry is full.
pub export fn ex_term_result_create(runtime_handle: i64, word: i64) i64 {
    if (runtime_handle == 0) return 0;
    const instance: *Runtime = @ptrFromInt(@as(usize, @bitCast(runtime_handle)));
    result_lock.lock();
    defer result_lock.unlock();

    var offset: usize = 0;
    while (offset < result_slot_cap) : (offset += 1) {
        const index = (result_cursor + offset) % result_slot_cap;
        const slot = &result_slots[index];
        if (slot.runtime == null) {
            slot.runtime = instance;
            slot.word = word;
            result_cursor = (index + 1) % result_slot_cap;
            return result_handle(index, slot.generation);
        }
    }
    if (active_runtime == instance) active_runtime = null;
    if (owned_runtime == instance) owned_runtime = null;
    instance.deinit();
    return 0;
}

/// Releases a result and the execution runtime it owns.
pub export fn ex_term_result_destroy(handle: i64) i64 {
    result_lock.lock();
    const slot = result_slot_locked(handle) orelse {
        result_lock.unlock();
        return -1;
    };
    const instance = slot.runtime.?;
    slot.runtime = null;
    slot.word = 0;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    result_lock.unlock();

    if (active_runtime == instance) {
        active_runtime = null;
        current_process_ptr = null;
    }
    if (owned_runtime == instance) owned_runtime = null;
    instance.deinit();
    return 0;
}

/// Classifies the root. Untagged scalar returns remain scalar even when their
/// low bits happen to resemble a heap tag.
pub export fn ex_term_result_root_kind(handle: i64) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    return if (runtime_owns_word(slot.runtime.?, slot.word))
        @intCast(word_tag(slot.word))
    else
        0;
}

pub export fn ex_term_result_root_word(handle: i64) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    return slot.word;
}

pub export fn ex_term_result_term_kind(handle: i64, word: i64) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    return result_term_kind_locked(slot, word);
}

pub export fn ex_term_result_term_length(handle: i64, word: i64) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    const kind = result_term_kind_locked(slot, word);
    return switch (kind) {
        tag_tuple => @intCast(tuple_len(word)),
        tag_list => @intCast(list_len(word)),
        tag_map => @intCast(map_len(word)),
        tag_binary => @intCast(binary_len(word)),
        tag_fun => fun_words(word)[1],
        else => -1,
    };
}

pub export fn ex_term_result_term_get(handle: i64, word: i64, index_word: i64) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    if (index_word < 0) return -1;
    const index: usize = @intCast(index_word);
    const kind = result_term_kind_locked(slot, word);
    return switch (kind) {
        tag_tuple => if (index < tuple_len(word)) tuple_elems(word)[index] else -1,
        tag_map => if (index < map_len(word) * 2) map_entries(word)[index] else -1,
        tag_binary => if (index < binary_len(word)) binary_bytes(word)[index] else -1,
        tag_fun => if (index < @as(usize, @intCast(fun_words(word)[1])) + 1)
            fun_words(word)[index * 0 + index]
        else
            -1,
        tag_list => blk: {
            var current = word;
            var cursor: usize = 0;
            while (word_tag(current) == tag_list and cursor < index) : (cursor += 1) {
                current = list_cell(current)[1];
            }
            if (word_tag(current) != tag_list) break :blk -1;
            break :blk list_cell(current)[0];
        },
        else => -1,
    };
}

fn init_processes() void {
    const instance = runtime();
    for (instance.processes[0..instance.process_count]) |proc| {
        std.heap.page_allocator.destroy(proc);
    }
    const initial = std.heap.page_allocator.create(Process) catch
        @panic("failed to allocate initial Batata process");
    initial.* = .{
        .pid = pid_of(0, 1),
        .generation = 1,
        .clock = .{ .budget = 0, .used = 0, .epoch = 0 },
    };
    instance.processes[0] = initial;
    instance.process_count = 1;
    instance.free_count = 0;
    instance.claim_cursor = 0;
    current_process = 0;
    current_process_ptr = initial;
    instance.unique_integer_counter = 0;
    instance.monitor_ref_counter = 0;
    // Each program run starts with a fresh bump arena: the scheduler driver
    // calls `process_table_reset` at the top, so terms allocated by a
    // previous run must not accumulate toward the fixed heap limit.
    reset_arena(instance);
}

fn current_proc() *Process {
    if (current_process_ptr) |proc| return proc;
    const instance = runtime();
    if (!instance.processes_initialized) {
        init_processes();
        instance.processes_initialized = true;
    }
    const proc = instance.processes[current_process];
    current_process_ptr = proc;
    return proc;
}

// pid layout: payload = (generation << index_bits) | (index + 1), tagged as an
// atom. index_bits = 24 supports ~16M concurrent slots; the generation is the
// BEAM serial that makes recycled-slot pids unique over time.
const index_bits: u6 = 24;
const index_mask: i64 = (1 << @intCast(index_bits)) - 1;

fn pid_of(index: usize, generation: u32) i64 {
    const payload = (@as(i64, @intCast(generation)) << @intCast(index_bits)) |
        @as(i64, @intCast(index + 1));
    return (payload << @intCast(tag_shift)) | @as(i64, @intCast(tag_atom));
}

fn pid_index(pid: i64) usize {
    const id = (word_payload(pid) & index_mask) - 1;
    return if (id < 0) 0 else @intCast(id);
}

/// Resolves a pid to its process, validating the generation: a stale pid
/// whose slot has been recycled carries an old serial and resolves to null.
/// The caller must hold the scheduler lock so process_count and slot reuse are
/// observed consistently. Process addresses remain stable across table growth.
fn resolve_pid(instance: *Runtime, pid: i64) ?*Process {
    const index = pid_index(pid);
    if (index >= instance.process_count) return null;
    const proc = instance.processes[index];
    return if (proc.pid == pid) proc else null;
}

/// Resets the process table to a single fresh initial process with the given
/// capacity (1..max_process_cap). The scheduler driver calls this at program
/// start so each run observes a clean actor table (processes/mailboxes do not
/// leak across `Batata.execute` calls). Returns 1, or nil when the capacity
/// is out of range.
pub export fn ex_term_process_table_reset(cap: i64) i64 {
    const instance = runtime();
    if (cap < 1) return nil_word;
    const new_cap: usize = @intCast(cap);
    if (instance.processes.len != new_cap) {
        for (instance.processes[0..instance.process_count]) |proc| {
            std.heap.page_allocator.destroy(proc);
        }
        instance.process_count = 0;
        if (instance.processes.len > 0) std.heap.page_allocator.free(instance.processes);
        if (instance.free_slots.len > 0) std.heap.page_allocator.free(instance.free_slots);
        instance.processes = std.heap.page_allocator.alloc(*Process, new_cap) catch
            @panic("failed to allocate Batata process table");
        instance.free_slots = std.heap.page_allocator.alloc(usize, new_cap) catch
            @panic("failed to allocate Batata process free list");
        instance.process_cap = new_cap;
    }
    // Starting an execution also resets all thread-owned transient state. The
    // segmented arena allocations themselves are retained for reuse.
    instance.yield_count = 0;
    jmp_depth = 0;
    throw_value = 0;
    init_processes();
    instance.processes_initialized = true;
    return 1;
}

// Preemptive yield accounting (#35 slice 3): the compiled loop driver
// charges slices of the reduction budget; each slice boundary is a yield
// point. The epoch is checked across slices (a message arrival or scheduler
// round bumps it, invalidating the continuation).
// Logical-clock counter for `erlang.unique_integer/0,1`: every call hands out
// a fresh value, so positive results are strictly increasing and negative
// results strictly decreasing (the single-threaded runtime makes them
// naturally monotonic across processes as well).
// A stack of setjmp buffers for non-local exits (`throw`). The setjmp call
// itself happens in the compiled code (so its frame stays live); the runtime
// only tracks the buffers and performs the longjmp. The scalar slice has no
// stack-owned resources to clean up, so a plain longjmp is safe.
threadlocal var jmp_stack: [16]*c.jmp_buf = undefined;
threadlocal var jmp_depth: usize = 0;
threadlocal var throw_value: i64 = 0;
// The worker boundary is distinct from user try frames, so programs retain
// all 16 nested catch slots. An otherwise uncaught throw lands here and exits
// only the current actor instead of panicking the native runtime.
threadlocal var uncaught_boundary: ?*c.jmp_buf = null;

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

/// Throws a value to the innermost try region. A worker catches otherwise
/// uncaught values at the actor boundary; calls outside a worker still abort.
pub export fn ex_term_throw(value: i64) noreturn {
    throw_value = value;
    if (jmp_depth > 0) c.longjmp(jmp_stack[jmp_depth - 1], 1);
    if (uncaught_boundary) |boundary| c.longjmp(boundary, 1);
    @panic("uncaught throw outside an actor boundary");
}

/// Returns the value delivered by the most recent throw (called from the
/// catch region after the longjmp returns).
pub export fn ex_term_catch_value() i64 {
    return throw_value;
}

/// Returns the pid of the current execution context. The scalar slice runs a
/// single actor with pid 1 (the atom term with id 1).
pub export fn ex_term_self() i64 {
    return current_proc().pid;
}

/// Enqueues a message to the process's mailbox, routing by pid; returns the
/// message itself, or nil when the pid is invalid or the mailbox is full.
/// Message delivery does not bump the recipient's epoch in this slice: a
/// plain FIFO receive must observe the message on resume.
pub export fn ex_term_send(pid: i64, msg: i64) i64 {
    const sender = current_proc().pid;
    if (word_tag(pid) != tag_atom) return nil_word;
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const target = resolve_pid(instance, pid) orelse return nil_word;
    if (!target.mailbox.push(sender, msg)) return nil_word;
    // Message arrival invalidates a pending selective-receive continuation:
    // the scan restarts and observes the new message (epoch invalidation
    // wiring, #35 slice 6). Loop continuations are unaffected.
    target.state_lock.lock();
    defer target.state_lock.unlock();
    if (target.cont.active and target.cont.receive) {
        target.clock.epoch += 1;
    }
    if (target.status == .waiting) target.status = .runnable;
    return msg;
}

/// Dequeues the oldest message; nil when the mailbox is empty.
pub export fn ex_term_receive() i64 {
    return current_proc().mailbox.pop() orelse nil_word;
}

/// The nil term word (atom id 0).
pub export fn ex_term_nil() i64 {
    return nil_word;
}

/// The current process's `receive ... after` timeout start; 0 when the wait
/// loop has not started timing yet.
pub export fn ex_term_receive_start() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return proc.receive_start;
}

/// Sets the current process's `receive ... after` timeout start.
pub export fn ex_term_receive_start_set(value: i64) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.receive_start = value;
    return value;
}

/// Wall-clock milliseconds (UTC epoch) for `receive ... after` timeouts.
pub export fn ex_term_monotonic_time() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * 1000 +
        @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

/// The BEAM native time unit (nanoseconds on 64-bit) for
/// `erlang.monotonic_time/0,1`.
pub export fn ex_term_native_time() i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * 1_000_000_000 + @as(i64, ts.tv_nsec);
}

/// Hands out a fresh logical-clock value for `erlang.unique_integer/0,1`;
/// `negative` selects the decreasing negative series.
pub export fn ex_term_unique_integer(negative: i64) i64 {
    const instance = runtime();
    instance.counter_lock.lock();
    defer instance.counter_lock.unlock();
    instance.unique_integer_counter += 1;
    return if (negative == 0) instance.unique_integer_counter else -instance.unique_integer_counter;
}

/// Number of messages in the current process's mailbox.
pub export fn ex_term_mailbox_len() i64 {
    return @intCast(current_proc().mailbox.count());
}

/// The message at `cursor` (0-based from the mailbox head) without removing
/// it; nil when out of range.
pub export fn ex_term_mailbox_peek(cursor: i64) i64 {
    const proc = current_proc();
    if (cursor < 0) return nil_word;
    return proc.mailbox.peek(@intCast(cursor)) orelse nil_word;
}

/// Removes the message at `cursor`, shifting later messages forward; returns
/// 1, or nil when out of range.
pub export fn ex_term_mailbox_remove(cursor: i64) i64 {
    const proc = current_proc();
    if (cursor < 0) return nil_word;
    return if (proc.mailbox.remove(@intCast(cursor))) 1 else nil_word;
}

/// Resets the mailbox. The compiled entry function calls this at the start of
/// the first slice; resumed slices skip it (guarded by the continuation check
/// in the lift) so messages that arrived while the process was suspended are
/// preserved.
pub export fn ex_term_mailbox_clear() i64 {
    current_proc().mailbox.clear();
    return nil_word;
}

/// Spawns a new process with its own mailbox, clock and entry closure;
/// returns its pid (atom word with generation + slot serial, #50 stage 2).
/// A completed process's slot is recycled first (stage 1) with a bumped
/// generation; otherwise the table grows dynamically, so spawn only fails on
/// allocation failure. `process_count` grows only to the concurrency peak.
pub export fn ex_term_spawn(fun: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();

    const reused = instance.free_count > 0;
    const index =
        if (reused) blk: {
            instance.free_count -= 1;
            break :blk instance.free_slots[instance.free_count];
        } else blk: {
            if (instance.process_count >= instance.processes.len) {
                grow_process_table(instance, instance.process_count + 1);
            }
            const fresh = instance.process_count;
            instance.process_count += 1;
            break :blk fresh;
        };

    const generation: u32 = if (reused) instance.processes[index].generation +% 1 else 1;

    const proc =
        if (reused)
            instance.processes[index]
        else blk: {
            const fresh = std.heap.page_allocator.create(Process) catch
                @panic("failed to allocate Batata process");
            instance.processes[index] = fresh;
            break :blk fresh;
        };

    // Reset the recycled slot completely: mailbox, continuation, clock,
    // status, result and entry are all fresh, so no message or continuation
    // residue from the previous occupant leaks into the new process.
    proc.* = .{
        .pid = pid_of(index, generation),
        .generation = generation,
        .clock = .{ .budget = 0, .used = 0, .epoch = 0 },
        .entry = fun,
    };
    return proc.pid;
}

/// Grows the process table (and its free list) to cover `needed` slots. The
/// caller holds the scheduler lock; allocation failure aborts.
fn grow_process_table(instance: *Runtime, needed: usize) void {
    if (needed <= instance.processes.len) return;
    const new_cap = @max(instance.processes.len * 2, needed);

    const new_processes = std.heap.page_allocator.alloc(*Process, new_cap) catch
        @panic("failed to grow Batata process table");
    @memcpy(new_processes[0..instance.process_count], instance.processes[0..instance.process_count]);
    std.heap.page_allocator.free(instance.processes);
    instance.processes = new_processes;

    const new_free = std.heap.page_allocator.alloc(usize, new_cap) catch
        @panic("failed to grow Batata process free list");
    @memcpy(new_free[0..instance.free_count], instance.free_slots[0..instance.free_count]);
    std.heap.page_allocator.free(instance.free_slots);
    instance.free_slots = new_free;
    instance.process_cap = new_cap;
}

/// Saves the current process's cursor-loop continuation (list, acc, cursor)
/// at the current epoch. Returns 1.
pub export fn ex_term_cont_save(arg: i64, acc: i64, cursor: i64) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.cont = .{
        .active = true,
        .epoch = proc.clock.epoch,
        .arg = arg,
        .acc = acc,
        .cursor = cursor,
        .receive = false,
    };
    return 1;
}

/// Saves a selective-receive continuation (mailbox scan state): unlike a
/// cursor-loop continuation, message arrival invalidates it.
pub export fn ex_term_receive_cont_save(arg: i64, acc: i64, cursor: i64) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.cont = .{
        .active = true,
        .epoch = proc.clock.epoch,
        .arg = arg,
        .acc = acc,
        .cursor = cursor,
        .receive = true,
    };
    return 1;
}

/// 1 when the current process has a continuation saved at the current epoch;
/// a message arrival bumps the epoch, so stale continuations read as not
/// pending.
pub export fn ex_term_cont_pending() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active and proc.cont.epoch == proc.clock.epoch) 1 else 0;
}

/// 1 when the current process has any saved continuation (valid or stale).
/// The entry's mailbox reset is gated on this: a resume — even one whose
/// continuation was invalidated by a message arrival — must keep the messages
/// that arrived while the process was suspended.
pub export fn ex_term_cont_active() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active) 1 else 0;
}

/// Clears the current process's saved continuation.
pub export fn ex_term_cont_clear() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.cont.active = false;
    return 0;
}

/// Saved loop state (arg/acc/cursor) of the current process's continuation;
/// nil when none is pending.
pub export fn ex_term_cont_load_arg() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active) proc.cont.arg else nil_word;
}

pub export fn ex_term_cont_load_acc() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active) proc.cont.acc else nil_word;
}

pub export fn ex_term_cont_load_cursor() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active) proc.cont.cursor else nil_word;
}

/// Advances to the next runnable process (round-robin from the current one)
/// and returns its pid. Stays on the current process when it is the only
/// runnable one.
pub export fn ex_term_schedule_next() i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    if (instance.process_count <= 1) return instance.processes[0].pid;
    var i: usize = 1;
    while (i <= instance.process_count) : (i += 1) {
        const index = (current_process + i) % instance.process_count;
        if (instance.processes[index].status == .runnable) {
            current_process = index;
            current_process_ptr = instance.processes[index];
            return instance.processes[index].pid;
        }
    }
    return instance.processes[current_process].pid;
}

/// Atomically claims one runnable actor for a non-zero worker id. The actor
/// remains runnable while owned, but no second worker can claim it.
pub export fn ex_term_process_claim_next(worker_id: i64) i64 {
    if (worker_id <= 0 or worker_id > std.math.maxInt(u32)) return nil_word;
    const owner: u32 = @intCast(worker_id);
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();

    for (0..instance.process_count) |offset| {
        const index = (instance.claim_cursor + offset) % instance.process_count;
        const proc = instance.processes[index];
        if (proc.status != .runnable) continue;
        if (proc.owner.cmpxchgStrong(0, owner, .acq_rel, .acquire) == null) {
            const previous_worker = proc.last_worker.swap(owner, .acq_rel);
            if (previous_worker != 0 and previous_worker != owner) {
                _ = instance.migrations.fetchAdd(1, .acq_rel);
            }
            current_process = index;
            current_process_ptr = proc;
            instance.claim_cursor = (index + 1) % instance.process_count;
            return proc.pid;
        }
    }
    return nil_word;
}

/// Releases the actor claimed by this worker after a yielded slice.
pub export fn ex_term_process_release() i64 {
    const proc = current_proc();
    const pid = proc.pid;
    proc.owner.store(0, .release);
    return pid;
}

/// Parks the current actor only when no message was appended beyond the
/// completed selective-receive scan cursor. Holding the mailbox lock across
/// the state transition prevents a lost wakeup with a concurrent send.
pub export fn ex_term_process_wait(cursor: i64) i64 {
    if (cursor < 0) return -1;
    const instance = runtime();
    const proc = current_proc();
    // Global lock order is scheduler -> mailbox -> process state. Send uses
    // the same order, preventing both lost wakeups and lock inversion.
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    proc.mailbox.lock.lock();
    defer proc.mailbox.lock.unlock();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();

    if (proc.mailbox.len <= @as(usize, @intCast(cursor))) {
        proc.status = .waiting;
        return 1;
    }
    return 0;
}

fn processes_unfinished() usize {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    var count: usize = 0;
    for (0..instance.process_count) |index| {
        const status = instance.processes[index].status;
        if (status != .done and status != .exited) count += 1;
    }
    return count;
}

const Worker = struct {
    instance: *Runtime,
    id: u32,
    dispatcher: *const fn (i64) callconv(.c) i64,

    fn run(self: @This()) void {
        active_runtime = self.instance;
        arena_worker_id = self.id;
        current_process = 0;
        current_process_ptr = null;

        while (true) {
            const pid = ex_term_process_claim_next(self.id);
            if (pid != nil_word) {
                current_proc().last_thread_id.store(@intCast(std.Thread.getCurrentId()), .release);
                const active = self.instance.active_actors.fetchAdd(1, .acq_rel) + 1;
                update_atomic_max(&self.instance.max_active_actors, active);
                var boundary: c.jmp_buf = undefined;
                uncaught_boundary = &boundary;

                if (c.setjmp(&boundary) == 0) {
                    const result = self.dispatcher(pid);
                    uncaught_boundary = null;
                    _ = self.instance.active_actors.fetchSub(1, .acq_rel);
                    _ = ex_term_process_done(result);
                } else {
                    const reason = throw_value;
                    jmp_depth = 0;
                    uncaught_boundary = null;
                    _ = self.instance.active_actors.fetchSub(1, .acq_rel);
                    _ = ex_term_process_exit(reason);
                }
                continue;
            }

            if (processes_unfinished() == 0) break;
            std.Thread.yield() catch {};
        }

        active_runtime = null;
        arena_worker_id = 0;
        current_process = 0;
        current_process_ptr = null;
    }
};

fn update_atomic_max(value: *std.atomic.Value(u32), candidate: u32) void {
    var current = value.load(.acquire);
    while (candidate > current) {
        current = value.cmpxchgWeak(current, candidate, .acq_rel, .acquire) orelse return;
    }
}

/// Runs all actors to completion using exactly `worker_count` OS workers.
/// The caller participates as worker 1; additional workers are joined before
/// the entry process result is returned.
pub export fn ex_term_worker_run(
    worker_count: i64,
    dispatcher: ?*const fn (i64) callconv(.c) i64,
) i64 {
    if (worker_count <= 0 or worker_count > 64 or dispatcher == null) return -1;
    const instance = runtime();
    instance.configured_workers.store(@intCast(worker_count), .release);
    instance.active_actors.store(0, .release);
    instance.max_active_actors.store(0, .release);
    instance.migrations.store(0, .release);
    const count: usize = @intCast(worker_count);
    const background_count = count - 1;
    const threads = std.heap.page_allocator.alloc(std.Thread, background_count) catch return -1;
    defer std.heap.page_allocator.free(threads);

    var started: usize = 0;
    for (threads, 0..) |*thread, index| {
        thread.* = std.Thread.spawn(.{}, Worker.run, .{
            Worker{
                .instance = instance,
                .id = @intCast(index + 2),
                .dispatcher = dispatcher.?,
            },
        }) catch break;
        started += 1;
    }

    Worker.run(.{ .instance = instance, .id = 1, .dispatcher = dispatcher.? });
    for (threads[0..started]) |thread| thread.join();
    if (started != background_count) return -1;

    active_runtime = instance;
    return ex_term_process_result(pid_of(0, 1));
}

pub export fn ex_term_worker_count() i64 {
    return runtime().configured_workers.load(.acquire);
}

pub export fn ex_term_worker_max_active() i64 {
    return runtime().max_active_actors.load(.acquire);
}

pub export fn ex_term_worker_migrations() i64 {
    return @intCast(runtime().migrations.load(.acquire));
}

pub export fn ex_term_process_thread_id(pid: i64) i64 {
    const instance = runtime();
    if (word_tag(pid) != tag_atom) return 0;
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const proc = resolve_pid(instance, pid) orelse return 0;
    return @intCast(proc.last_thread_id.load(.acquire));
}

/// Closure word of the current process's entry; 0 for the initial process
/// (the compiled `__batata_entry`).
pub export fn ex_term_current_entry() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return proc.entry;
}

// The caller holds scheduler_lock. Signal delivery follows the remaining
// global lock order (mailbox -> process state) and wakes a waiting actor.
fn deliver_signal_locked(
    target: *Process,
    kind: SignalKind,
    sender: i64,
    payload: i64,
) bool {
    if (!target.mailbox.pushSignal(kind, sender, payload)) return false;
    target.state_lock.lock();
    defer target.state_lock.unlock();
    if (target.cont.active and target.cont.receive) target.clock.epoch += 1;
    if (target.status == .waiting) target.status = .runnable;
    return true;
}

fn remove_link_locked(proc: *Process, peer: i64) void {
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    var i: usize = 0;
    while (i < proc.link_count) {
        if (proc.links[i].peer == peer) {
            proc.link_count -= 1;
            proc.links[i] = proc.links[proc.link_count];
            return;
        }
        i += 1;
    }
}

fn notify_monitors_locked(instance: *Runtime, proc: *Process, reason: ?i64) void {
    for (proc.monitors[0..proc.monitor_count]) |monitor| {
        const watcher = resolve_pid(instance, monitor.watcher) orelse continue;
        const down = tuple5(
            monitor.down_tag,
            monitor.reference,
            monitor.process_tag,
            proc.pid,
            reason orelse monitor.normal_tag,
        );
        if (down != nil_word) _ = deliver_signal_locked(watcher, .down, proc.pid, down);
    }
    proc.monitor_count = 0;
}

fn detach_watched_by_locked(instance: *Runtime, watcher_pid: i64) void {
    for (instance.processes[0..instance.process_count]) |target| {
        target.state_lock.lock();
        var i: usize = 0;
        while (i < target.monitor_count) {
            if (target.monitors[i].watcher == watcher_pid) {
                target.monitor_count -= 1;
                target.monitors[i] = target.monitors[target.monitor_count];
            } else {
                i += 1;
            }
        }
        target.state_lock.unlock();
    }
}

fn propagate_exit_locked(instance: *Runtime, proc: *Process, reason: i64) void {
    proc.state_lock.lock();
    if (proc.status == .done or proc.status == .exited) {
        proc.state_lock.unlock();
        return;
    }
    proc.status = .exited;
    proc.exit_reason = reason;
    proc.cont.active = false;
    const link_count = proc.link_count;
    proc.link_count = 0;
    proc.state_lock.unlock();

    // Scheduler serialization keeps the detached link array stable while the
    // termination wave removes reverse links and visits peers.
    for (proc.links[0..link_count]) |link| {
        const peer = resolve_pid(instance, link.peer) orelse continue;
        remove_link_locked(peer, proc.pid);
        peer.state_lock.lock();
        const traps = peer.trap_exit;
        const peer_terminal = peer.status == .done or peer.status == .exited;
        peer.state_lock.unlock();
        if (peer_terminal) continue;
        if (traps) {
            const exit_message = tuple3(link.exit_tag, proc.pid, reason);
            if (exit_message != nil_word) _ = deliver_signal_locked(peer, .exit, proc.pid, exit_message);
        } else if (reason != link.normal_tag) {
            propagate_exit_locked(instance, peer, reason);
        }
    }

    notify_monitors_locked(instance, proc, reason);
    detach_watched_by_locked(instance, proc.pid);
    if (pid_index(proc.pid) > 0 and instance.free_count < instance.free_slots.len) {
        instance.free_slots[instance.free_count] = pid_index(proc.pid);
        instance.free_count += 1;
    }
    proc.owner.store(0, .release);
}

/// Marks the current process done and stores its result.
pub export fn ex_term_process_done(result: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const proc = current_proc();
    proc.state_lock.lock();
    if (!proc.cont.active and proc.status == .runnable) {
        proc.status = .done;
        proc.result = result;
        const link_count = proc.link_count;
        proc.link_count = 0;
        proc.state_lock.unlock();

        for (proc.links[0..link_count]) |link| {
            const peer = resolve_pid(instance, link.peer) orelse continue;
            remove_link_locked(peer, proc.pid);
            peer.state_lock.lock();
            const traps = peer.trap_exit;
            peer.state_lock.unlock();
            if (traps) {
                const exit_message = tuple3(link.exit_tag, proc.pid, link.normal_tag);
                if (exit_message != nil_word) _ = deliver_signal_locked(peer, .exit, proc.pid, exit_message);
            }
        }
        notify_monitors_locked(instance, proc, null);
        detach_watched_by_locked(instance, proc.pid);
        // Recycle the slot for future spawns (#50 stage 1). Slot 0 is the
        // per-run entry process and is always reset by the driver.
        if (current_process > 0 and instance.free_count < instance.free_slots.len) {
            instance.free_slots[instance.free_count] = current_process;
            instance.free_count += 1;
        }
    } else {
        proc.state_lock.unlock();
    }
    proc.owner.store(0, .release);
    return result;
}

/// Marks the current process as abnormally exited and records its reason.
/// The owner is always released so other actors and workers can continue.
pub export fn ex_term_process_exit(reason: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const proc = current_proc();
    propagate_exit_locked(instance, proc, reason);
    return reason;
}

/// Sets the current process's trap-exit flag and returns its previous value.
pub export fn ex_term_process_trap_exit(enabled: i64) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    const previous: i64 = if (proc.trap_exit) 1 else 0;
    proc.trap_exit = enabled != 0;
    return previous;
}

/// Creates a symmetric link. Atom words for EXIT and normal are supplied by
/// compiled code because atom identifiers are program hashes, not runtime IDs.
pub export fn ex_term_link(pid: i64, exit_tag: i64, normal_tag: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const source = current_proc();
    const target = resolve_pid(instance, pid) orelse return nil_word;
    if (source == target) return pid;

    source.state_lock.lock();
    target.state_lock.lock();
    defer target.state_lock.unlock();
    defer source.state_lock.unlock();
    if (source.status == .done or source.status == .exited or
        target.status == .done or target.status == .exited or
        source.link_count >= relation_cap or target.link_count >= relation_cap) return nil_word;
    for (source.links[0..source.link_count]) |link| if (link.peer == pid) return pid;
    source.links[source.link_count] = .{ .peer = pid, .exit_tag = exit_tag, .normal_tag = normal_tag };
    source.link_count += 1;
    target.links[target.link_count] = .{ .peer = source.pid, .exit_tag = exit_tag, .normal_tag = normal_tag };
    target.link_count += 1;
    return pid;
}

/// Removes both sides of a link; returns 1 when the target pid is live.
pub export fn ex_term_unlink(pid: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const source = current_proc();
    const target = resolve_pid(instance, pid) orelse return 0;
    remove_link_locked(source, pid);
    remove_link_locked(target, source.pid);
    return 1;
}

/// Sends an exit signal without creating a link. A trapping target receives
/// `{EXIT, from, reason}`; a non-trapping target exits unless reason is normal.
pub export fn ex_term_exit(pid: i64, reason: i64, exit_tag: i64, normal_tag: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const source_pid = current_proc().pid;
    const target = resolve_pid(instance, pid) orelse return nil_word;
    target.state_lock.lock();
    const traps = target.trap_exit;
    const terminal = target.status == .done or target.status == .exited;
    target.state_lock.unlock();
    if (terminal) return nil_word;
    if (traps) {
        const exit_message = tuple3(exit_tag, source_pid, reason);
        if (exit_message == nil_word or !deliver_signal_locked(target, .exit, source_pid, exit_message))
            return nil_word;
    } else if (reason != normal_tag) {
        propagate_exit_locked(instance, target, reason);
    }
    return reason;
}

/// Monitors a live process and returns a fresh tagged-integer reference.
pub export fn ex_term_monitor(
    pid: i64,
    down_tag: i64,
    process_tag: i64,
    normal_tag: i64,
) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const target = resolve_pid(instance, pid) orelse return nil_word;
    target.state_lock.lock();
    defer target.state_lock.unlock();
    if (target.status == .done or target.status == .exited or target.monitor_count >= relation_cap)
        return nil_word;
    instance.monitor_ref_counter += 1;
    const reference = instance.monitor_ref_counter << @intCast(tag_shift);
    target.monitors[target.monitor_count] = .{
        .watcher = current_proc().pid,
        .reference = reference,
        .down_tag = down_tag,
        .process_tag = process_tag,
        .normal_tag = normal_tag,
    };
    target.monitor_count += 1;
    return reference;
}

/// Removes a monitor owned by the current process; returns 1 when found.
pub export fn ex_term_demonitor(reference: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const watcher = current_proc().pid;
    for (instance.processes[0..instance.process_count]) |target| {
        target.state_lock.lock();
        for (0..target.monitor_count) |i| {
            const monitor = target.monitors[i];
            if (monitor.watcher == watcher and monitor.reference == reference) {
                target.monitor_count -= 1;
                target.monitors[i] = target.monitors[target.monitor_count];
                target.state_lock.unlock();
                return 1;
            }
        }
        target.state_lock.unlock();
    }
    return 0;
}

/// Number of runnable processes (the scheduler driver loops while > 0).
pub export fn ex_term_processes_runnable() i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    var count: i64 = 0;
    for (0..instance.process_count) |i| {
        if (instance.processes[i].status == .runnable) count += 1;
    }
    return count;
}

/// Result of a completed process; nil when the process is unknown or still
/// runnable.
pub export fn ex_term_process_result(pid: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    if (word_tag(pid) != tag_atom) return nil_word;
    const proc = resolve_pid(instance, pid) orelse return nil_word;
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.status == .done) proc.result else nil_word;
}

/// Returns an abnormally exited process's reason; nil for a live, normally
/// completed, stale or unknown pid.
pub export fn ex_term_process_exit_reason(pid: i64) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    if (word_tag(pid) != tag_atom) return nil_word;
    const proc = resolve_pid(instance, pid) orelse return nil_word;
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.status == .exited) proc.exit_reason else nil_word;
}

/// Sets the reduction budget and resets the used counter (epoch untouched).
pub export fn ex_term_clock_init(budget: i64) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.clock.budget = budget;
    proc.clock.used = 0;
    return budget;
}

/// Charges `cost` reductions; returns 1 when the budget is exhausted (the
/// caller should yield), else 0. Negative cost is clamped to zero.
pub export fn ex_term_clock_tick(cost: i64) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    if (cost > 0) proc.clock.used += cost;
    return if (proc.clock.used >= proc.clock.budget and proc.clock.budget > 0) 1 else 0;
}

/// Remaining reduction budget (clamped to >= 0); -1 when no budget is set.
pub export fn ex_term_clock_budget_left() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    if (proc.clock.budget <= 0) return -1;
    const left = proc.clock.budget - proc.clock.used;
    return if (left < 0) 0 else left;
}

/// Current continuation-generation counter.
pub export fn ex_term_clock_epoch() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return proc.clock.epoch;
}

/// Bumps the epoch (message arrival / scheduler round); returns the new value.
pub export fn ex_term_clock_bump_epoch() i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.clock.epoch += 1;
    const result = proc.clock.epoch;
    return result;
}

/// Number of preemptive yields so far (slice boundaries in the loop driver).
pub export fn ex_term_yield_count() i64 {
    const instance = runtime();
    instance.counter_lock.lock();
    defer instance.counter_lock.unlock();
    return instance.yield_count;
}

/// Records one yield at a slice boundary and bumps the yield counter.
pub export fn ex_term_yield_mark() i64 {
    const instance = runtime();
    instance.counter_lock.lock();
    defer instance.counter_lock.unlock();
    instance.yield_count += 1;
    return instance.yield_count;
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

/// Maps an enumerable by calling a compiled mapper `(item: i64) -> i64` on
/// each item, producing a list in order. Items are untagged integers; the
/// mapped scalar is tagged as an int term in the result.
pub export fn ex_term_enumerable_map_fun(
    enumerable: i64,
    mapper: ?*const fn (i64) callconv(.c) i64,
) i64 {
    const count = ex_term_enumerable_count(enumerable);
    var result = nil_word;
    var i: i64 = count;
    while (i > 0) {
        i -= 1;
        const item =
            switch (word_tag(enumerable)) {
                tag_list => ex_term_list_get(enumerable, i),
                tag_tuple => ex_term_tuple_get(enumerable, i),
                tag_binary => (binary_bytes(enumerable)[@intCast(i)] << @intCast(tag_shift)),
                else => nil_word,
            };
        const mapped = mapper.?(word_value(item));
        result = ex_term_list_cons(mapped << @intCast(tag_shift), result);
    }
    return result;
}

/// Filters a list by a compiled predicate `(item: i64) -> i64` (nonzero
/// keeps), producing a list in order.
pub export fn ex_term_stream_filter(
    list: i64,
    predicate: ?*const fn (i64) callconv(.c) i64,
) i64 {
    if (word_tag(list) != tag_list) return nil_word;
    const count = list_len(list);
    var result = nil_word;
    var i: i64 = @intCast(count);
    while (i > 0) {
        i -= 1;
        const item = ex_term_list_get(list, i);
        if (predicate.?(word_value(item)) != 0) {
            result = ex_term_list_cons(item, result);
        }
    }
    return result;
}

/// Takes the first n elements of a list (n clamped to [0, len]).
pub export fn ex_term_stream_take(list: i64, n: i64) i64 {
    if (word_tag(list) != tag_list) return nil_word;
    const len: i64 = @intCast(list_len(list));
    const take_n = if (n < 0) 0 else @min(n, len);
    var result = nil_word;
    var i: i64 = take_n;
    while (i > 0) {
        i -= 1;
        result = ex_term_list_cons(ex_term_list_get(list, i), result);
    }
    return result;
}

/// Drops the first n elements of a list (n clamped to [0, len]).
pub export fn ex_term_stream_drop(list: i64, n: i64) i64 {
    if (word_tag(list) != tag_list) return nil_word;
    const len: i64 = @intCast(list_len(list));
    const skip = if (n < 0) 0 else @min(n, len);
    var result = nil_word;
    var i: i64 = len;
    while (i > skip) {
        i -= 1;
        result = ex_term_list_cons(ex_term_list_get(list, i), result);
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
/// Registers a native callback entry (fn_id, function pointer). Returns 0 on
/// success, -1 when the id is out of range.
pub export fn ex_term_register_callback(
    fn_id: i64,
    callback: ?*const fn (i64) callconv(.c) i64,
) i64 {
    if (fn_id < 0 or fn_id >= beam_callback_cap) return -1;
    const instance = runtime();
    instance.callback_lock.lock();
    defer instance.callback_lock.unlock();
    instance.callbacks[@intCast(fn_id)] = callback;
    return 0;
}

/// Calls a registered native callback entry with an argument word; -1 when
/// the id is out of range or not registered.
pub export fn ex_term_call_callback(fn_id: i64, arg: i64) i64 {
    if (fn_id < 0 or fn_id >= beam_callback_cap) return -1;
    const instance = runtime();
    instance.callback_lock.lock();
    const callback = instance.callbacks[@intCast(fn_id)] orelse {
        instance.callback_lock.unlock();
        return -1;
    };
    instance.callback_lock.unlock();
    return callback(arg);
}

fn list_contains(list: i64, word: i64) bool {
    var current = list;
    while (word_tag(current) == tag_list) {
        if (list_cell(current)[0] == word) return true;
        current = list_cell(current)[1];
    }
    return false;
}

/// Builds a set (unique members) from a list. Members keep their term words;
/// duplicate members are dropped. Order is not preserved (sets are unordered).
pub export fn ex_term_mapset_from_list(list: i64) i64 {
    var result = nil_word;
    var current = list;
    while (word_tag(current) == tag_list) {
        const item = list_cell(current)[0];
        if (!list_contains(result, item)) {
            result = ex_term_list_cons(item, result);
        }
        current = list_cell(current)[1];
    }
    return result;
}

/// Membership check: 1 when the set contains the member word, else 0.
pub export fn ex_term_mapset_member(set: i64, member: i64) i64 {
    return if (word_tag(set) == tag_list and list_contains(set, member)) 1 else 0;
}

/// Adds a member to a set (deduplicated); the original set is returned when
/// the member is already present.
pub export fn ex_term_mapset_put(set: i64, member: i64) i64 {
    if (ex_term_mapset_member(set, member) == 1) return set;
    return ex_term_list_cons(member, set);
}

fn path_binary_to_slice(binary: i64, out: []u8) ?[]const u8 {
    if (word_tag(binary) != tag_binary) return null;
    const len = binary_len(binary);
    if (len > out.len) return null;
    const bytes = binary_bytes(binary);
    for (0..len) |i| {
        out[i] = @intCast(bytes[i] & 0xFF);
    }
    return out[0..len];
}

fn read_file_binary(path_word: i64) ?i64 {
    var path_buf: [4096]u8 = undefined;
    const path = path_binary_to_slice(path_word, &path_buf) orelse return null;
    if (path.len >= 4096) return null;
    path_buf[path.len] = 0;
    const z_path: [:0]u8 = path_buf[0..path.len :0];
    const file = c.fopen(z_path.ptr, "rb") orelse return null;
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) return null;
    const size = c.ftell(file);
    if (size < 0 or size > 32 * 1024 * 1024) return null;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return null;
    const file_len: usize = @intCast(size);
    const words = alloc_binary(file_len) orelse return null;
    const binary = word_from_ptr(words, tag_binary);
    const bytes = binary_bytes(binary);
    for (0..file_len) |i| {
        const ch = c.fgetc(file);
        if (ch == c.EOF) return null;
        bytes[i] = @intCast(ch);
    }
    return binary;
}

/// Reads a file into a binary term; nil for missing files, non-binary paths,
/// or oversized content.
pub export fn ex_term_file_read(path_word: i64) i64 {
    return read_file_binary(path_word) orelse nil_word;
}

/// Reads a file and splits it into a list of line binaries (without trailing
/// newlines); nil on read failure.
pub export fn ex_term_file_read_lines(path_word: i64) i64 {
    const file_binary = read_file_binary(path_word) orelse return nil_word;
    const len = binary_len(file_binary);
    const file_bytes = binary_bytes(file_binary);
    var result = nil_word;
    var line_start: usize = len;
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        if (file_bytes[i] == '\n') {
            // 行是 [i+1, line_start)
            const line_len = line_start - (i + 1);
            const line = alloc_binary(line_len) orelse return nil_word;
            const line_word = word_from_ptr(line, tag_binary);
            const line_bytes = binary_bytes(line_word);
            var j: usize = 0;
            while (j < line_len) : (j += 1) {
                line_bytes[j] = file_bytes[i + 1 + j];
            }
            result = ex_term_list_cons(line_word, result);
            line_start = i;
        }
    }
    // 剩余行 [0, line_start)（无换行结尾或首行）
    if (line_start > 0) {
        const line_len = line_start;
        const line = alloc_binary(line_len) orelse return nil_word;
        const line_word = word_from_ptr(line, tag_binary);
        const line_bytes = binary_bytes(line_word);
        var j: usize = 0;
        while (j < line_len) : (j += 1) {
            line_bytes[j] = file_bytes[j];
        }
        result = ex_term_list_cons(line_word, result);
    }
    return result;
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
    const slice = alloc_binary(rest_len) orelse return nil_word;
    const slice_word = word_from_ptr(slice, tag_binary);
    const slice_bytes = binary_bytes(slice_word);
    const bytes = binary_bytes(binary);
    var i: usize = 0;
    while (i < rest_len) : (i += 1) {
        slice_bytes[i] = bytes[@as(usize, @intCast(start)) + i];
    }
    return slice_word;
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
    const words = alloc_binary(out_len) orelse return nil_word;
    const result = word_from_ptr(words, tag_binary);
    const out = binary_bytes(result);
    const bytes = binary_bytes(binary);
    const hex = "0123456789ABCDEF";
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const b: u8 = @intCast(bytes[i] & 0xFF);
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0F];
    }
    return result;
}

fn hex_value(b: u8) i8 {
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
    const words = alloc_binary(out_len) orelse return nil_word;
    const result = word_from_ptr(words, tag_binary);
    const out = binary_bytes(result);
    const bytes = binary_bytes(binary);
    var i: usize = 0;
    while (i < len) : (i += 2) {
        const hi = hex_value(bytes[i]);
        const lo = hex_value(bytes[i + 1]);
        if (hi < 0 or lo < 0) return nil_word;
        out[i / 2] = @intCast(@as(i64, hi) << 4 | lo);
    }
    return result;
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
    const words = alloc_binary(i) orelse return nil_word;
    const result = word_from_ptr(words, tag_binary);
    const out = binary_bytes(result);
    var j: usize = 0;
    while (j < i) : (j += 1) {
        out[j] = digits[i - 1 - j];
    }
    return result;
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
    const binary = alloc_binary(len) orelse return nil_word;
    const result = word_from_ptr(binary, tag_binary);
    const bytes = binary_bytes(result);

    var current = list;
    var i: usize = 0;
    while (word_tag(current) == tag_list) {
        const cell: *[2]i64 = @ptrFromInt(@as(usize, @bitCast(current)) & ~tag_mask);
        const byte = if (is_int(cell[0])) word_payload(cell[0]) & 0xFF else 0;
        bytes[i] = @intCast(byte);
        i += 1;
        current = cell[1];
    }

    return result;
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
    @export(&ex_term_runtime_create, .{ .name = "ex.term.runtime_create" });
    @export(&ex_term_runtime_enter, .{ .name = "ex.term.runtime_enter" });
    @export(&ex_term_runtime_leave, .{ .name = "ex.term.runtime_leave" });
    @export(&ex_term_runtime_destroy, .{ .name = "ex.term.runtime_destroy" });
    @export(&ex_term_result_create, .{ .name = "ex.term.result_create" });
    @export(&ex_term_result_destroy, .{ .name = "ex.term.result_destroy" });
    @export(&ex_term_result_root_kind, .{ .name = "ex.term.result_root_kind" });
    @export(&ex_term_result_root_word, .{ .name = "ex.term.result_root_word" });
    @export(&ex_term_result_term_kind, .{ .name = "ex.term.result_term_kind" });
    @export(&ex_term_result_term_length, .{ .name = "ex.term.result_term_length" });
    @export(&ex_term_result_term_get, .{ .name = "ex.term.result_term_get" });
    @export(&ex_term_self, .{ .name = "ex.term.self" });
    @export(&ex_term_send, .{ .name = "ex.term.send" });
    @export(&ex_term_receive, .{ .name = "ex.term.receive" });
    @export(&ex_term_nil, .{ .name = "ex.term.nil" });
    @export(&ex_term_monotonic_time, .{ .name = "ex.term.monotonic_time" });
    @export(&ex_term_native_time, .{ .name = "ex.term.native_time" });
    @export(&ex_term_unique_integer, .{ .name = "ex.term.unique_integer" });
    @export(&ex_term_receive_start, .{ .name = "ex.term.receive_start" });
    @export(&ex_term_receive_start_set, .{ .name = "ex.term.receive_start_set" });
    @export(&ex_term_mailbox_len, .{ .name = "ex.term.mailbox_len" });
    @export(&ex_term_mailbox_peek, .{ .name = "ex.term.mailbox_peek" });
    @export(&ex_term_mailbox_remove, .{ .name = "ex.term.mailbox_remove" });
    @export(&ex_term_mailbox_clear, .{ .name = "ex.term.mailbox_clear" });
    @export(&ex_term_spawn, .{ .name = "ex.term.spawn" });
    @export(&ex_term_process_table_reset, .{ .name = "ex.term.process_table_reset" });
    @export(&ex_term_cont_save, .{ .name = "ex.term.cont_save" });
    @export(&ex_term_receive_cont_save, .{ .name = "ex.term.receive_cont_save" });
    @export(&ex_term_cont_pending, .{ .name = "ex.term.cont_pending" });
    @export(&ex_term_cont_active, .{ .name = "ex.term.cont_active" });
    @export(&ex_term_cont_clear, .{ .name = "ex.term.cont_clear" });
    @export(&ex_term_cont_load_arg, .{ .name = "ex.term.cont_load_arg" });
    @export(&ex_term_cont_load_acc, .{ .name = "ex.term.cont_load_acc" });
    @export(&ex_term_cont_load_cursor, .{ .name = "ex.term.cont_load_cursor" });
    @export(&ex_term_schedule_next, .{ .name = "ex.term.schedule_next" });
    @export(&ex_term_process_claim_next, .{ .name = "ex.term.process_claim_next" });
    @export(&ex_term_process_release, .{ .name = "ex.term.process_release" });
    @export(&ex_term_process_wait, .{ .name = "ex.term.process_wait" });
    @export(&ex_term_worker_run, .{ .name = "ex.term.worker_run" });
    @export(&ex_term_worker_count, .{ .name = "ex.term.worker_count" });
    @export(&ex_term_worker_max_active, .{ .name = "ex.term.worker_max_active" });
    @export(&ex_term_worker_migrations, .{ .name = "ex.term.worker_migrations" });
    @export(&ex_term_process_thread_id, .{ .name = "ex.term.process_thread_id" });
    @export(&ex_term_current_entry, .{ .name = "ex.term.current_entry" });
    @export(&ex_term_process_done, .{ .name = "ex.term.process_done" });
    @export(&ex_term_process_exit, .{ .name = "ex.term.process_exit" });
    @export(&ex_term_process_trap_exit, .{ .name = "ex.term.process_trap_exit" });
    @export(&ex_term_link, .{ .name = "ex.term.link" });
    @export(&ex_term_unlink, .{ .name = "ex.term.unlink" });
    @export(&ex_term_exit, .{ .name = "ex.term.exit" });
    @export(&ex_term_monitor, .{ .name = "ex.term.monitor" });
    @export(&ex_term_demonitor, .{ .name = "ex.term.demonitor" });
    @export(&ex_term_processes_runnable, .{ .name = "ex.term.processes_runnable" });
    @export(&ex_term_process_result, .{ .name = "ex.term.process_result" });
    @export(&ex_term_process_exit_reason, .{ .name = "ex.term.process_exit_reason" });
    @export(&ex_term_clock_init, .{ .name = "ex.term.clock_init" });
    @export(&ex_term_clock_tick, .{ .name = "ex.term.clock_tick" });
    @export(&ex_term_clock_budget_left, .{ .name = "ex.term.clock_budget_left" });
    @export(&ex_term_clock_epoch, .{ .name = "ex.term.clock_epoch" });
    @export(&ex_term_clock_bump_epoch, .{ .name = "ex.term.clock_bump_epoch" });
    @export(&ex_term_yield_count, .{ .name = "ex.term.yield_count" });
    @export(&ex_term_yield_mark, .{ .name = "ex.term.yield_mark" });
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
    @export(&ex_term_enumerable_map_fun, .{ .name = "ex.term.enumerable_map_fun" });
    @export(&ex_term_stream_filter, .{ .name = "ex.term.stream_filter" });
    @export(&ex_term_stream_take, .{ .name = "ex.term.stream_take" });
    @export(&ex_term_stream_drop, .{ .name = "ex.term.stream_drop" });
    @export(&ex_term_enumerable_reduce, .{ .name = "ex.term.enumerable_reduce" });
    @export(&ex_term_enumerable_reduce_c, .{ .name = "ex.term.enumerable_reduce_c" });
    @export(&ex_term_enumerable_reduce_range, .{ .name = "ex.term.enumerable_reduce_range" });
    @export(&ex_term_enumerable_reduce_fun, .{ .name = "ex.term.enumerable_reduce_fun" });
    @export(&ex_term_register_callback, .{ .name = "ex.term.register_callback" });
    @export(&ex_term_call_callback, .{ .name = "ex.term.call_callback" });
    @export(&ex_term_mapset_from_list, .{ .name = "ex.term.mapset_from_list" });
    @export(&ex_term_mapset_member, .{ .name = "ex.term.mapset_member" });
    @export(&ex_term_mapset_put, .{ .name = "ex.term.mapset_put" });
    @export(&ex_term_file_read, .{ .name = "ex.term.file_read" });
    @export(&ex_term_file_read_lines, .{ .name = "ex.term.file_read_lines" });
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

    // enumerable map by compiled mapper: x * 2 over list/tuple/binary
    const mapped_list = ex_term_enumerable_map_fun(list, &test_mapper_double);
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(mapped_list));
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_head(mapped_list) >> @intCast(tag_shift));
    const mapped_tuple = ex_term_enumerable_map_fun(tuple, &test_mapper_double);
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(mapped_tuple));
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_head(mapped_tuple) >> @intCast(tag_shift));
    const mapped_binary = ex_term_enumerable_map_fun(count_bin, &test_mapper_double);
    try std.testing.expectEqual(@as(i64, 3), ex_term_list_length(mapped_binary));
    try std.testing.expectEqual(@as(i64, 4), ex_term_list_head(ex_term_list_tail(mapped_binary)) >> @intCast(tag_shift));

    // stream filter: keep even items (predicate: item % 2 == 0)
    const filtered = ex_term_stream_filter(list, &test_predicate_even);
    try std.testing.expectEqual(@as(i64, 1), ex_term_list_length(filtered));
    try std.testing.expectEqual(two, ex_term_list_head(filtered));

    // stream take/drop
    const three_list = ex_term_list_cons(one, ex_term_list_cons(two, ex_term_list_cons(two, nil_word)));
    const taken = ex_term_stream_take(three_list, 2);
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(taken));
    try std.testing.expectEqual(one, ex_term_list_head(taken));
    try std.testing.expectEqual(@as(i64, 0), ex_term_list_length(ex_term_stream_take(three_list, 0)));
    const dropped = ex_term_stream_drop(three_list, 1);
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(dropped));
    try std.testing.expectEqual(two, ex_term_list_head(dropped));
    try std.testing.expectEqual(@as(i64, 0), ex_term_list_length(ex_term_stream_drop(three_list, 9)));

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

    // MapSet: dedupe construction, membership, put
    const dup_list = ex_term_list_cons(one, ex_term_list_cons(two, ex_term_list_cons(one, nil_word)));
    const set = ex_term_mapset_from_list(dup_list);
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(set));
    try std.testing.expectEqual(@as(i64, 1), ex_term_mapset_member(set, one));
    try std.testing.expectEqual(@as(i64, 1), ex_term_mapset_member(set, two));
    try std.testing.expectEqual(@as(i64, 0), ex_term_mapset_member(set, 24));
    const set2 = ex_term_mapset_put(set, 24);
    try std.testing.expectEqual(@as(i64, 3), ex_term_list_length(set2));
    try std.testing.expectEqual(@as(i64, 2), ex_term_list_length(ex_term_mapset_put(set, one)));

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

fn test_mapper_double(item: i64) callconv(.c) i64 {
    return item * 2;
}

fn test_predicate_even(item: i64) callconv(.c) i64 {
    return if (@rem(item, 2) == 0) 1 else 0;
}

fn test_binary_from_string(s: []const u8) i64 {
    var list = nil_word;
    var i: usize = s.len;
    while (i > 0) {
        i -= 1;
        list = ex_term_list_cons(@as(i64, s[i]) << @intCast(tag_shift), list);
    }
    return ex_term_binary_from_list(list);
}

test "term ABI file read and lines" {
    const tmp_path = "/tmp/batata_zig_file_test.txt";
    const wf = c.fopen(tmp_path, "wb") orelse unreachable;
    _ = c.fwrite("alpha\nbeta\ngamma", 1, 16, wf);
    _ = c.fclose(wf);
    const path_word = test_binary_from_string(tmp_path);
    const content = ex_term_file_read(path_word);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_binary(content));
    try std.testing.expectEqual(@as(i64, 16), ex_term_binary_length(content));
    const expected_content = test_binary_from_string("alpha\nbeta\ngamma");
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(content, expected_content));
    const lines = ex_term_file_read_lines(path_word);
    try std.testing.expectEqual(@as(i64, 3), ex_term_list_length(lines));
    const first = ex_term_list_head(lines);
    try std.testing.expectEqual(@as(i64, 5), ex_term_binary_length(first));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_file_read(test_binary_from_string("/tmp/definitely_missing_batata_file"))));
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
    const first_signal = current_proc().mailbox.peekSignal(0).?;
    const second_signal = current_proc().mailbox.peekSignal(1).?;
    try std.testing.expectEqual(SignalKind.message, first_signal.kind);
    try std.testing.expectEqual(pid, first_signal.sender);
    try std.testing.expectEqual(@as(u64, 0), first_signal.sequence);
    try std.testing.expectEqual(@as(u64, 1), second_signal.sequence);
    try std.testing.expectEqual(one, ex_term_receive());
    try std.testing.expectEqual(two, ex_term_receive());
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_receive()));

    // integer untag
    try std.testing.expectEqual(@as(i64, 1), ex_term_to_int(one));
    try std.testing.expectEqual(@as(i64, 2), ex_term_to_int(two));
    try std.testing.expectEqual(@as(i64, 0), ex_term_to_int(ex_term_self()));

    // reduction clock: init budget, tick charges, exhausted -> 1, epoch.
    // Message delivery bumps the epoch only for receive-type continuations
    // (selective-receive scans), so the first explicit bump returns 1.
    try std.testing.expectEqual(@as(i64, 1), ex_term_clock_bump_epoch());
    try std.testing.expectEqual(@as(i64, 10), ex_term_clock_init(10));
    try std.testing.expectEqual(@as(i64, 10), ex_term_clock_budget_left());
    try std.testing.expectEqual(@as(i64, 0), ex_term_clock_tick(4));
    try std.testing.expectEqual(@as(i64, 6), ex_term_clock_budget_left());
    try std.testing.expectEqual(@as(i64, 1), ex_term_clock_tick(6));
    try std.testing.expectEqual(@as(i64, 0), ex_term_clock_budget_left());
    try std.testing.expectEqual(@as(i64, 1), ex_term_clock_tick(1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_clock_epoch());
    try std.testing.expectEqual(@as(i64, 2), ex_term_clock_bump_epoch());
    try std.testing.expectEqual(@as(i64, 2), ex_term_clock_epoch());
    try std.testing.expectEqual(@as(i64, 0), ex_term_clock_budget_left());

    // yield accounting
    try std.testing.expectEqual(@as(i64, 0), ex_term_yield_count());
    try std.testing.expectEqual(@as(i64, 1), ex_term_yield_mark());
    try std.testing.expectEqual(@as(i64, 2), ex_term_yield_mark());
    try std.testing.expectEqual(@as(i64, 2), ex_term_yield_count());

    // spawn: new process with an isolated mailbox and entry closure; send
    // routes by pid
    const fun = ex_term_make_fun(1, 0, 0, 0, 0, 0);
    const pid2 = ex_term_spawn(fun);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_atom(pid2));
    try std.testing.expectEqual(one, ex_term_send(pid2, one));
    // current process (pid 1) mailbox is unaffected by sends to pid2
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_receive()));
    // send back to self routes to the current process
    const pid1 = ex_term_self();
    try std.testing.expectEqual(one, ex_term_send(pid1, one));
    try std.testing.expectEqual(one, ex_term_receive());

    // continuation: save/load round-trip on the current process
    try std.testing.expectEqual(@as(i64, 0), ex_term_cont_pending());
    try std.testing.expectEqual(@as(i64, 1), ex_term_cont_save(10, 20, 30));
    try std.testing.expectEqual(@as(i64, 1), ex_term_cont_pending());
    try std.testing.expectEqual(@as(i64, 10), ex_term_cont_load_arg());
    try std.testing.expectEqual(@as(i64, 20), ex_term_cont_load_acc());
    try std.testing.expectEqual(@as(i64, 30), ex_term_cont_load_cursor());
    try std.testing.expectEqual(@as(i64, 0), ex_term_cont_clear());
    try std.testing.expectEqual(@as(i64, 0), ex_term_cont_pending());

    // epoch invalidation: an explicit clock_bump_epoch invalidates a saved
    // continuation, so it reads as not pending (the entry restarts)
    try std.testing.expectEqual(@as(i64, 1), ex_term_cont_save(1, 2, 3));
    try std.testing.expectEqual(@as(i64, 3), ex_term_clock_bump_epoch());
    try std.testing.expectEqual(@as(i64, 0), ex_term_cont_pending());
    try std.testing.expectEqual(@as(i64, 0), ex_term_cont_clear());

    // mailbox scan: len/peek/remove support selective receive
    try std.testing.expectEqual(@as(i64, 0), ex_term_mailbox_len());
    try std.testing.expectEqual(one, ex_term_send(pid1, one));
    try std.testing.expectEqual(two, ex_term_send(pid1, two));
    try std.testing.expectEqual(@as(i64, 2), ex_term_mailbox_len());
    try std.testing.expectEqual(one, ex_term_mailbox_peek(0));
    try std.testing.expectEqual(two, ex_term_mailbox_peek(1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_mailbox_peek(2)));
    // removing the middle message (index 1) leaves [one]
    try std.testing.expectEqual(@as(i64, 1), ex_term_mailbox_remove(1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_mailbox_len());
    try std.testing.expectEqual(one, ex_term_mailbox_peek(0));
    try std.testing.expectEqual(one, ex_term_receive());

    // receive-type continuation: a message arrival invalidates it, so the
    // selective-receive scan restarts and observes the new message
    try std.testing.expectEqual(@as(i64, 1), ex_term_receive_cont_save(0, 0, 1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_cont_pending());
    try std.testing.expectEqual(one, ex_term_send(pid1, one));
    try std.testing.expectEqual(@as(i64, 0), ex_term_cont_pending());
    try std.testing.expectEqual(@as(i64, 0), ex_term_cont_clear());

    // loop-type continuation: a message arrival does NOT invalidate it
    try std.testing.expectEqual(@as(i64, 1), ex_term_cont_save(1, 2, 3));
    try std.testing.expectEqual(one, ex_term_send(pid1, one));
    try std.testing.expectEqual(@as(i64, 1), ex_term_cont_pending());
    try std.testing.expectEqual(@as(i64, 0), ex_term_cont_clear());

    // scheduler: spawn registers entries; schedule_next round-robins
    // runnable processes; process_done parks a process with its result
    try std.testing.expectEqual(@as(i64, 0), ex_term_current_entry());
    const pid3 = ex_term_spawn(fun);
    try std.testing.expectEqual(@as(i64, 3), ex_term_processes_runnable());
    try std.testing.expectEqual(pid2, ex_term_schedule_next());
    try std.testing.expectEqual(fun, ex_term_current_entry());
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_process_result(pid2)));
    try std.testing.expectEqual(one, ex_term_process_done(one));
    try std.testing.expectEqual(one, ex_term_process_result(pid2));
    try std.testing.expectEqual(@as(i64, 2), ex_term_processes_runnable());
    // the next slice skips the done process and picks pid3
    try std.testing.expectEqual(pid3, ex_term_schedule_next());

    // process table reset: a fresh program run starts with only the initial
    // process, so spawns work again after a previous run filled the table
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    try std.testing.expectEqual(@as(i64, 1), ex_term_processes_runnable());
    try std.testing.expectEqual(@as(i64, 0), ex_term_current_entry());
    const pid4 = ex_term_spawn(fun);
    try std.testing.expectEqual(@as(i64, 2), ex_term_processes_runnable());
    try std.testing.expectEqual(pid4, ex_term_schedule_next());
}

test "process table capacity is an initial allocation that grows on spawn" {
    // cap = 1: the initial process occupies the only slot; spawn grows the
    // table dynamically (#50 stage 2) instead of failing.
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_processes_runnable());
    _ = ex_term_spawn(nil_word);
    try std.testing.expectEqual(@as(i64, 2), ex_term_processes_runnable());

    // cap = 2: a burst of spawns beyond the initial allocation still succeeds
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(2));
    try std.testing.expectEqual(@as(i64, 1), ex_term_processes_runnable());
    _ = ex_term_spawn(nil_word);
    _ = ex_term_spawn(nil_word);
    _ = ex_term_spawn(nil_word);
    _ = ex_term_spawn(nil_word);
    try std.testing.expectEqual(@as(i64, 5), ex_term_processes_runnable());

    // out-of-range capacities are rejected and leave the table untouched
    try std.testing.expectEqual(nil_word, ex_term_process_table_reset(0));
    try std.testing.expectEqual(@as(i64, 5), ex_term_processes_runnable());
}

const RuntimeIsolationProbe = struct {
    ready: std.atomic.Value(u32) = .init(0),
    thread_ids: [2]std.Thread.Id = undefined,
    unique_values: [2]i64 = undefined,
    runnable_counts: [2]i64 = undefined,
    yield_counts: [2]i64 = undefined,

    fn run(self: *@This(), slot: usize, increments: usize, spawned: usize) void {
        _ = ex_term_process_table_reset(default_process_cap);
        self.thread_ids[slot] = std.Thread.getCurrentId();

        for (0..increments) |_| _ = ex_term_unique_integer(0);
        for (0..spawned) |_| _ = ex_term_spawn(nil_word);
        for (0..spawned) |_| _ = ex_term_yield_mark();

        _ = self.ready.fetchAdd(1, .acq_rel);
        while (self.ready.load(.acquire) != self.thread_ids.len) std.Thread.yield() catch {};

        self.unique_values[slot] = ex_term_unique_integer(0);
        self.runnable_counts[slot] = ex_term_processes_runnable();
        self.yield_counts[slot] = ex_term_yield_count();
    }
};

test "runtime state is isolated across concurrent OS threads" {
    var probe = RuntimeIsolationProbe{};
    const first = try std.Thread.spawn(.{}, RuntimeIsolationProbe.run, .{ &probe, 0, 2, 1 });
    const second = try std.Thread.spawn(.{}, RuntimeIsolationProbe.run, .{ &probe, 1, 5, 3 });
    first.join();
    second.join();

    try std.testing.expect(probe.thread_ids[0] != probe.thread_ids[1]);
    try std.testing.expectEqual(@as(i64, 3), probe.unique_values[0]);
    try std.testing.expectEqual(@as(i64, 6), probe.unique_values[1]);
    try std.testing.expectEqual(@as(i64, 2), probe.runnable_counts[0]);
    try std.testing.expectEqual(@as(i64, 4), probe.runnable_counts[1]);
    try std.testing.expectEqual(@as(i64, 1), probe.yield_counts[0]);
    try std.testing.expectEqual(@as(i64, 3), probe.yield_counts[1]);
}

test "explicit runtime handles preserve isolated execution state" {
    const first = ex_term_runtime_create();
    const second = ex_term_runtime_create();

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(first));
    _ = ex_term_process_table_reset(default_process_cap);
    try std.testing.expectEqual(@as(i64, 1), ex_term_unique_integer(0));
    _ = ex_term_spawn(nil_word);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(second));
    _ = ex_term_process_table_reset(default_process_cap);
    try std.testing.expectEqual(@as(i64, 1), ex_term_unique_integer(0));
    try std.testing.expectEqual(@as(i64, 1), ex_term_processes_runnable());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(first));
    try std.testing.expectEqual(@as(i64, 2), ex_term_unique_integer(0));
    try std.testing.expectEqual(@as(i64, 2), ex_term_processes_runnable());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(first));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(second));
}

test "host result handles retain terms and reject stale generations" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    const tuple = tuple3(8, 16, 24);
    const handle = ex_term_result_create(runtime_handle, tuple);
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    try std.testing.expectEqual(@as(i64, tag_tuple), ex_term_result_root_kind(handle));
    try std.testing.expectEqual(tuple, ex_term_result_root_word(handle));
    try std.testing.expectEqual(@as(i64, 3), ex_term_result_term_length(handle, tuple));
    try std.testing.expectEqual(@as(i64, 16), ex_term_result_term_get(handle, tuple, 1));
    try std.testing.expectEqual(@as(i64, tag_int), ex_term_result_term_kind(handle, 16));

    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_root_kind(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_destroy(handle));
}

test "host result roots preserve untagged scalar compatibility" {
    const runtime_handle = ex_term_runtime_create();
    const handle = ex_term_result_create(runtime_handle, 3);
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_root_kind(handle));
    try std.testing.expectEqual(@as(i64, 3), ex_term_result_root_word(handle));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(handle));
}

test "segmented arena grows beyond the former fixed heap without moving terms" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    const first = alloc_words(2).?;
    first[0] = 101;
    first[1] = 202;

    for (0..65) |_| {
        const segment = alloc_words(arena_chunk_words).?;
        segment[0] = 303;
    }

    try std.testing.expectEqual(@as(i64, 101), first[0]);
    try std.testing.expectEqual(@as(i64, 202), first[1]);
    try std.testing.expect(runtime().arena_chunk_count > 65);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(runtime_handle));
}

test "workers reserve independent bump segments" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    arena_worker_id = 7;
    const first = alloc_words(1).?;
    arena_worker_id = 8;
    const second = alloc_words(1).?;

    try std.testing.expect(@intFromPtr(first) != @intFromPtr(second));
    try std.testing.expectEqual(@as(u32, 7), runtime().arena_chunks[0].owner);
    try std.testing.expectEqual(@as(u32, 8), runtime().arena_chunks[1].owner);
    arena_worker_id = 0;
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(runtime_handle));
}

test "binary payload storage is byte packed" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    const words = alloc_binary(1024).?;
    try std.testing.expectEqual(@as(usize, 129), runtime().arena_chunks[0].bump);
    const binary = word_from_ptr(words, tag_binary);
    const bytes = binary_bytes(binary);
    bytes[0] = 17;
    bytes[1023] = 23;
    try std.testing.expectEqual(@as(u8, 17), binary_bytes(binary)[0]);
    try std.testing.expectEqual(@as(u8, 23), binary_bytes(binary)[1023]);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(runtime_handle));
}

const ActorClaimProbe = struct {
    handle: i64,
    ready: std.atomic.Value(u32) = .init(0),
    claimed: std.atomic.Value(u32) = .init(0),
    pids: [2]i64 = undefined,

    fn run(self: *@This(), slot: usize) void {
        _ = ex_term_runtime_enter(self.handle);
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (self.ready.load(.acquire) != self.pids.len) std.Thread.yield() catch {};

        self.pids[slot] = ex_term_process_claim_next(@intCast(slot + 1));
        _ = self.claimed.fetchAdd(1, .acq_rel);
        while (self.claimed.load(.acquire) != self.pids.len) std.Thread.yield() catch {};

        _ = ex_term_process_release();
        _ = ex_term_runtime_leave();
    }
};

test "workers claim distinct actors from one runtime" {
    const handle = ex_term_runtime_create();
    _ = ex_term_runtime_enter(handle);
    _ = ex_term_process_table_reset(default_process_cap);
    _ = ex_term_spawn(nil_word);
    _ = ex_term_runtime_leave();

    var probe = ActorClaimProbe{ .handle = handle };
    const first = try std.Thread.spawn(.{}, ActorClaimProbe.run, .{ &probe, 0 });
    const second = try std.Thread.spawn(.{}, ActorClaimProbe.run, .{ &probe, 1 });
    first.join();
    second.join();

    try std.testing.expect(probe.pids[0] != nil_word);
    try std.testing.expect(probe.pids[1] != nil_word);
    try std.testing.expect(probe.pids[0] != probe.pids[1]);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

const MailboxSendProbe = struct {
    handle: i64,
    pid: i64,

    fn run(self: @This(), slot: usize) void {
        _ = ex_term_runtime_enter(self.handle);
        for (0..16) |i| {
            const value: i64 = @intCast(slot * 16 + i);
            _ = ex_term_send(self.pid, value << @intCast(tag_shift));
        }
        _ = ex_term_runtime_leave();
    }
};

test "mailbox accepts concurrent cross-worker sends without loss" {
    const handle = ex_term_runtime_create();
    _ = ex_term_runtime_enter(handle);
    _ = ex_term_process_table_reset(default_process_cap);
    const pid = ex_term_self();
    _ = ex_term_runtime_leave();

    const probe = MailboxSendProbe{ .handle = handle, .pid = pid };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, slot| {
        thread.* = try std.Thread.spawn(.{}, MailboxSendProbe.run, .{ probe, slot });
    }
    for (threads) |thread| thread.join();

    _ = ex_term_runtime_enter(handle);
    try std.testing.expectEqual(@as(i64, 64), ex_term_mailbox_len());
    var seen = [_]bool{false} ** 64;
    for (0..64) |_| {
        const value = word_payload(ex_term_receive());
        try std.testing.expect(value >= 0 and value < seen.len);
        try std.testing.expect(!seen[@intCast(value)]);
        seen[@intCast(value)] = true;
    }
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

const WorkerPoolProbe = struct {
    ready: std.atomic.Value(u32) = .init(0),
    active: std.atomic.Value(u32) = .init(0),
    max_active: std.atomic.Value(u32) = .init(0),
    thread_ids: [2]std.Thread.Id = undefined,
};

var worker_pool_probe: *WorkerPoolProbe = undefined;

fn test_actor_dispatch(pid: i64) callconv(.c) i64 {
    const slot = pid_index(pid);
    worker_pool_probe.thread_ids[slot] = std.Thread.getCurrentId();
    _ = worker_pool_probe.active.fetchAdd(1, .acq_rel);
    _ = worker_pool_probe.ready.fetchAdd(1, .acq_rel);
    while (worker_pool_probe.ready.load(.acquire) != 2) std.Thread.yield() catch {};
    worker_pool_probe.max_active.store(2, .release);
    _ = worker_pool_probe.active.fetchSub(1, .acq_rel);
    return pid;
}

test "worker pool overlaps independent actors on distinct OS threads" {
    const handle = ex_term_runtime_create();
    _ = ex_term_runtime_enter(handle);
    _ = ex_term_process_table_reset(default_process_cap);
    const second_pid = ex_term_spawn(nil_word);

    var probe = WorkerPoolProbe{};
    worker_pool_probe = &probe;
    try std.testing.expectEqual(pid_of(0, 1), ex_term_worker_run(2, &test_actor_dispatch));
    try std.testing.expectEqual(second_pid, ex_term_process_result(second_pid));
    try std.testing.expect(probe.thread_ids[0] != probe.thread_ids[1]);
    try std.testing.expectEqual(@as(u32, 2), probe.max_active.load(.acquire));
    try std.testing.expectEqual(@as(i64, 2), ex_term_worker_count());
    try std.testing.expectEqual(@as(i64, 2), ex_term_worker_max_active());
    try std.testing.expect(ex_term_process_thread_id(pid_of(0, 1)) != ex_term_process_thread_id(second_pid));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

const FailureBoundaryProbe = struct {
    completed: std.atomic.Value(u32) = .init(0),
};

var failure_boundary_probe: *FailureBoundaryProbe = undefined;

fn failure_boundary_dispatch(pid: i64) callconv(.c) i64 {
    if (pid_index(pid) == 1) ex_term_throw(77 << @intCast(tag_shift));
    _ = failure_boundary_probe.completed.fetchAdd(1, .acq_rel);
    return pid;
}

test "uncaught throw exits only its actor and workers continue" {
    const handle = ex_term_runtime_create();
    _ = ex_term_runtime_enter(handle);
    _ = ex_term_process_table_reset(default_process_cap);
    const failed_pid = ex_term_spawn(nil_word);
    const survivor_pid = ex_term_spawn(nil_word);

    var probe = FailureBoundaryProbe{};
    failure_boundary_probe = &probe;
    try std.testing.expectEqual(pid_of(0, 1), ex_term_worker_run(2, &failure_boundary_dispatch));

    const reason = 77 << @intCast(tag_shift);
    try std.testing.expectEqual(@as(u32, 2), probe.completed.load(.acquire));
    try std.testing.expectEqual(reason, ex_term_process_exit_reason(failed_pid));
    try std.testing.expectEqual(nil_word, ex_term_process_result(failed_pid));
    try std.testing.expectEqual(survivor_pid, ex_term_process_result(survivor_pid));
    try std.testing.expectEqual(nil_word, ex_term_process_exit_reason(survivor_pid));

    // Reusing the failed slot bumps its generation and clears the recorded
    // reason. The stale pid can no longer observe its previous occupant.
    var replacement = ex_term_spawn(nil_word);
    while (pid_index(replacement) != pid_index(failed_pid)) {
        replacement = ex_term_spawn(nil_word);
    }
    try std.testing.expect(replacement != failed_pid);
    try std.testing.expectEqual(nil_word, ex_term_process_exit_reason(failed_pid));
    try std.testing.expectEqual(nil_word, ex_term_process_exit_reason(replacement));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

test "links and monitors deliver ordered EXIT and DOWN signals" {
    const exit_tag: i64 = (101 << @intCast(tag_shift)) | tag_atom;
    const down_tag: i64 = (102 << @intCast(tag_shift)) | tag_atom;
    const process_tag: i64 = (103 << @intCast(tag_shift)) | tag_atom;
    const normal_tag: i64 = (104 << @intCast(tag_shift)) | tag_atom;
    const reason: i64 = (105 << @intCast(tag_shift)) | tag_atom;

    _ = ex_term_process_table_reset(default_process_cap);
    const parent = ex_term_self();
    const child = ex_term_spawn(nil_word);
    try std.testing.expectEqual(@as(i64, 0), ex_term_process_trap_exit(1));
    try std.testing.expectEqual(child, ex_term_link(child, exit_tag, normal_tag));
    const reference = ex_term_monitor(child, down_tag, process_tag, normal_tag);
    try std.testing.expect(is_int(reference));

    try std.testing.expectEqual(child, ex_term_schedule_next());
    try std.testing.expectEqual(reason, ex_term_process_exit(reason));
    try std.testing.expectEqual(parent, ex_term_schedule_next());
    try std.testing.expectEqual(@as(i64, 2), ex_term_mailbox_len());

    const exit_signal = current_proc().mailbox.peekSignal(0).?;
    const down_signal = current_proc().mailbox.peekSignal(1).?;
    try std.testing.expectEqual(SignalKind.exit, exit_signal.kind);
    try std.testing.expectEqual(SignalKind.down, down_signal.kind);
    try std.testing.expect(exit_signal.sequence < down_signal.sequence);
    try std.testing.expectEqual(exit_tag, ex_term_tuple_get(exit_signal.payload, 0));
    try std.testing.expectEqual(child, ex_term_tuple_get(exit_signal.payload, 1));
    try std.testing.expectEqual(reason, ex_term_tuple_get(exit_signal.payload, 2));
    try std.testing.expectEqual(down_tag, ex_term_tuple_get(down_signal.payload, 0));
    try std.testing.expectEqual(reference, ex_term_tuple_get(down_signal.payload, 1));
    try std.testing.expectEqual(process_tag, ex_term_tuple_get(down_signal.payload, 2));
    try std.testing.expectEqual(child, ex_term_tuple_get(down_signal.payload, 3));
    try std.testing.expectEqual(reason, ex_term_tuple_get(down_signal.payload, 4));
}

test "unlink and demonitor suppress supervision signals" {
    const tag: i64 = (111 << @intCast(tag_shift)) | tag_atom;
    const reason: i64 = (112 << @intCast(tag_shift)) | tag_atom;

    _ = ex_term_process_table_reset(default_process_cap);
    const parent = ex_term_self();
    const child = ex_term_spawn(nil_word);
    try std.testing.expectEqual(child, ex_term_link(child, tag, tag));
    const reference = ex_term_monitor(child, tag, tag, tag);
    try std.testing.expectEqual(@as(i64, 1), ex_term_unlink(child));
    try std.testing.expectEqual(@as(i64, 1), ex_term_demonitor(reference));

    try std.testing.expectEqual(child, ex_term_schedule_next());
    try std.testing.expectEqual(reason, ex_term_process_exit(reason));
    try std.testing.expectEqual(parent, ex_term_schedule_next());
    try std.testing.expectEqual(@as(i64, 0), ex_term_mailbox_len());
    try std.testing.expectEqual(nil_word, ex_term_process_exit_reason(parent));
}

test "linked failures cascade while normal exits only notify trappers" {
    const exit_tag: i64 = (121 << @intCast(tag_shift)) | tag_atom;
    const normal_tag: i64 = (122 << @intCast(tag_shift)) | tag_atom;
    const failure: i64 = (123 << @intCast(tag_shift)) | tag_atom;

    _ = ex_term_process_table_reset(default_process_cap);
    const parent = ex_term_self();
    const child = ex_term_spawn(nil_word);
    try std.testing.expectEqual(child, ex_term_link(child, exit_tag, normal_tag));
    try std.testing.expectEqual(child, ex_term_schedule_next());
    _ = ex_term_process_exit(failure);
    try std.testing.expectEqual(failure, ex_term_process_exit_reason(parent));

    _ = ex_term_process_table_reset(default_process_cap);
    const trapping_parent = ex_term_self();
    const normal_child = ex_term_spawn(nil_word);
    _ = ex_term_process_trap_exit(1);
    _ = ex_term_link(normal_child, exit_tag, normal_tag);
    try std.testing.expectEqual(normal_child, ex_term_schedule_next());
    _ = ex_term_process_done(0);
    try std.testing.expectEqual(trapping_parent, ex_term_schedule_next());
    const exit_message = ex_term_receive();
    try std.testing.expectEqual(exit_tag, ex_term_tuple_get(exit_message, 0));
    try std.testing.expectEqual(normal_child, ex_term_tuple_get(exit_message, 1));
    try std.testing.expectEqual(normal_tag, ex_term_tuple_get(exit_message, 2));
    try std.testing.expectEqual(nil_word, ex_term_process_exit_reason(trapping_parent));
}

test "a completed dispatcher cannot overwrite an earlier explicit exit" {
    const tag: i64 = (131 << @intCast(tag_shift)) | tag_atom;
    const reason: i64 = (132 << @intCast(tag_shift)) | tag_atom;

    _ = ex_term_process_table_reset(default_process_cap);
    const pid = ex_term_self();
    try std.testing.expectEqual(reason, ex_term_exit(pid, reason, tag, tag));
    _ = ex_term_process_done(0);
    try std.testing.expectEqual(reason, ex_term_process_exit_reason(pid));
    try std.testing.expectEqual(nil_word, ex_term_process_result(pid));
}

test "shared immutable terms survive sender exit and slot reuse" {
    const ten: i64 = 10 << @intCast(tag_shift);
    const thirty_two: i64 = 32 << @intCast(tag_shift);

    _ = ex_term_process_table_reset(default_process_cap);
    const receiver = ex_term_self();
    const sender = ex_term_spawn(nil_word);
    const list = ex_term_list_cons(ten, ex_term_list_cons(thirty_two, nil_word));
    const tuple = ex_term_tuple_from_list(list);

    try std.testing.expectEqual(sender, ex_term_schedule_next());
    try std.testing.expectEqual(tuple, ex_term_send(receiver, tuple));
    _ = ex_term_process_done(0);
    try std.testing.expectEqual(receiver, ex_term_schedule_next());
    const retained = ex_term_receive();

    const replacement = ex_term_spawn(nil_word);
    try std.testing.expect(pid_index(replacement) == pid_index(sender));
    try std.testing.expect(replacement != sender);
    try std.testing.expectEqual(ten, ex_term_tuple_get(retained, 0));
    try std.testing.expectEqual(thirty_two, ex_term_tuple_get(retained, 1));
}

const ConcurrentGrowthProbe = struct {
    ready: std.atomic.Value(u32) = .init(0),
    reads: std.atomic.Value(u32) = .init(0),
    grown: std.atomic.Value(bool) = .init(false),
};

var concurrent_growth_probe: *ConcurrentGrowthProbe = undefined;

fn concurrent_growth_dispatch(pid: i64) callconv(.c) i64 {
    const slot = pid_index(pid);

    if (slot == 0) {
        _ = concurrent_growth_probe.ready.fetchAdd(1, .acq_rel);
        while (concurrent_growth_probe.ready.load(.acquire) != 2) std.Thread.yield() catch {};
        while (concurrent_growth_probe.reads.load(.acquire) == 0) std.Thread.yield() catch {};

        // The initial capacity is two. Every fresh spawn after the first two
        // actors forces the pointer table to grow while actor 1 is reading
        // through its stable Process allocation on the other worker.
        for (0..128) |_| _ = ex_term_spawn(nil_word);
        concurrent_growth_probe.grown.store(true, .release);
    } else if (slot == 1) {
        _ = concurrent_growth_probe.ready.fetchAdd(1, .acq_rel);
        while (!concurrent_growth_probe.grown.load(.acquire)) {
            _ = ex_term_mailbox_len();
            _ = concurrent_growth_probe.reads.fetchAdd(1, .acq_rel);
        }
    }

    return pid;
}

test "process addresses stay stable while another worker grows the table" {
    const handle = ex_term_runtime_create();
    _ = ex_term_runtime_enter(handle);
    _ = ex_term_process_table_reset(2);
    const second_pid = ex_term_spawn(nil_word);
    const instance = runtime();
    const before = resolve_pid(instance, second_pid).?;

    var probe = ConcurrentGrowthProbe{};
    concurrent_growth_probe = &probe;
    try std.testing.expectEqual(pid_of(0, 1), ex_term_worker_run(2, &concurrent_growth_dispatch));

    const after = resolve_pid(instance, second_pid).?;
    try std.testing.expect(before == after);
    try std.testing.expect(instance.processes.len >= 128);
    try std.testing.expect(probe.reads.load(.acquire) > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

test "completed process slots are recycled by spawn (#50 stage 1)" {
    const one: i64 = 1 << @intCast(tag_shift);

    _ = ex_term_process_table_reset(4);
    const fun = ex_term_make_fun(1, 0, 0, 0, 0, 0);

    const p2 = ex_term_spawn(fun);
    const p3 = ex_term_spawn(fun);
    const p4 = ex_term_spawn(fun);
    try std.testing.expectEqual(@as(i64, 4), ex_term_processes_runnable());

    // A message lands in p2's mailbox; then main and all three complete
    // (claim order is index 0..3; slot 0 is never recycled).
    _ = ex_term_send(p2, one);
    for (0..4) |_| {
        _ = ex_term_process_claim_next(1);
        _ = ex_term_process_done(one);
    }
    try std.testing.expectEqual(@as(i64, 0), ex_term_processes_runnable());
    _ = ex_term_process_claim_next(1);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_process_claim_next(1)));
    try std.testing.expectEqual(@as(i64, 0), ex_term_processes_runnable());

    // Spawn recycles completed slots (LIFO: p4, p3, then p2), so
    // process_count never grows past the concurrency peak. The recycled slot
    // carries a bumped pid generation (#50 stage 2): the new pid differs from
    // the old one but indexes the same slot.
    const r1 = ex_term_spawn(fun);
    const r2 = ex_term_spawn(fun);
    const r3 = ex_term_spawn(fun);
    try std.testing.expect(pid_index(r1) == pid_index(p4));
    try std.testing.expect(pid_index(r2) == pid_index(p3));
    try std.testing.expect(pid_index(r3) == pid_index(p2));
    try std.testing.expect(r1 != p4 and r2 != p3 and r3 != p2);
    try std.testing.expectEqual(@as(i64, 3), ex_term_processes_runnable());

    // The stale pids are rejected by the generation check; the fresh pids
    // resolve and deliver.
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_send(p4, one)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_send(p3, one)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_send(p2, one)));
    try std.testing.expectEqual(one, ex_term_send(r1, one));

    // The recycled p2 slot's mailbox was cleared: the message sent before
    // completion must not leak into the new occupant. Claim until we reach
    // the recycled p2 slot (r3).
    var reached_p2 = false;
    for (0..8) |_| {
        if (pid_index(ex_term_process_claim_next(1)) == pid_index(p2)) {
            reached_p2 = true;
            break;
        }
    }
    try std.testing.expect(reached_p2);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_receive()));

    // No free slots remain (r3 stays runnable) and the table is at its
    // initial capacity: spawn grows the table dynamically (#50 stage 2).
    const grown = ex_term_spawn(fun);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_atom(grown));
    try std.testing.expectEqual(@as(i64, 4), ex_term_processes_runnable());
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
