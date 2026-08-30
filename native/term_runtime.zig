//! Zig term runtime for the `ex` dialect.
//!
//! Implements the declaration-first ABI in `native/ABI.md`. All exported
//! symbols are C ABI functions over 64-bit tagged words; Beaver's ex
//! conversion plan emits calls to exactly these symbols.

const std = @import("std");
const builtin = @import("builtin");
pub const Extension = @import("extension.zig").Extension;
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
const fun_arity_marker: u64 = @as(u64, 1) << 61;
const fun_signature_marker: u64 = @as(u64, 1) << 60;
// Tag 7 is shared by arena-owned boxed numbers and immediate runtime-local
// words. The latter carry runtime_local_marker and are never arena pointers.
const tag_float: usize = 7;
const tag_runtime_local: usize = 7;
const result_kind_bigint: i64 = 8;
const boxed_float_kind: i64 = 1;
const boxed_bigint_kind: i64 = 2;

// Dynamic atoms occupy the high half of the atom payload space, disjoint from
// Batata's non-negative compile-time literal hashes. Their names live in the
// owning runtime and are intentionally not portable through codec v1.
const dynamic_atom_marker: u64 = @as(u64, 1) << 60;
const dynamic_atom_index_mask: u64 = dynamic_atom_marker - 1;
const dynamic_atom_cap: usize = 1024;

const tag_mask: usize = 7;
const tag_shift: u6 = 3;
const runtime_local_marker: u64 = @as(u64, 1) << 60;
const runtime_local_kind_shift: u6 = 59;
const runtime_local_data_mask: u64 = (@as(u64, 1) << runtime_local_kind_shift) - 1;
const runtime_local_pid: u64 = 0;
const runtime_local_ref: u64 = 1;

/// Nil is the atom term with id 0: tag_atom | (0 << 3).
const nil_word: i64 = 1;

// Heap layouts (all 8-byte aligned words):
//   tuple:  [len: i64] [elem: i64 ... len]
//   map:    [len: i64] [entry: i64 ... 2*len]   (flat key/value pairs)
//   binary: [len: i64] [packed byte: u8 ... len] [alignment padding]
//   list:   cons cells [head: i64] [tail: i64]
//   fun:    [fn_idx: i64] [env_len: i64] [env: i64 ... env_len]
//   float:  [kind: i64] [IEEE-754 bits: u64]
//   bigint: [kind: i64] [decimal byte len: i64] [packed canonical decimal bytes]

// Runtime instances own execution state. The compatibility path lazily binds
// one instance per OS thread; explicit handles let future actor workers enter
// the same execution without returning to process-global mutable storage.
const arena_chunk_words = 64 * 1024;
// The initial segmented-arena policy deliberately permits growth beyond the
// former 32 MiB heap without making long-running bump allocation unbounded.
const arena_chunk_cap = 128;
const arena_hard_limit_words = arena_chunk_cap * arena_chunk_words;
pub const arena_hard_limit_bytes = arena_hard_limit_words * @sizeOf(i64);
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

fn dynamic_atom_index(word: i64) ?usize {
    if (!is_atom(word)) return null;
    const payload = @as(u64, @bitCast(word)) >> tag_shift;
    if (payload & dynamic_atom_marker == 0) return null;
    const index = payload & dynamic_atom_index_mask;
    if (index >= dynamic_atom_cap) return null;
    return @intCast(index);
}

fn dynamic_atom_word(index: usize) i64 {
    const payload = dynamic_atom_marker | @as(u64, @intCast(index));
    return @bitCast((payload << tag_shift) | tag_atom);
}

fn runtime_local_word(kind: u64, data: u64) i64 {
    const payload = runtime_local_marker | (kind << runtime_local_kind_shift) | data;
    return @bitCast((payload << tag_shift) | tag_runtime_local);
}

fn runtime_local_kind(word: i64) ?u64 {
    if (word_tag(word) != tag_runtime_local) return null;
    const payload = @as(u64, @bitCast(word)) >> tag_shift;
    if (payload & runtime_local_marker == 0) return null;
    return (payload >> runtime_local_kind_shift) & 1;
}

fn runtime_local_data(word: i64) u64 {
    return (@as(u64, @bitCast(word)) >> tag_shift) & runtime_local_data_mask;
}

fn is_pid(word: i64) bool {
    return runtime_local_kind(word) == runtime_local_pid;
}

fn is_runtime_ref(word: i64) bool {
    return runtime_local_kind(word) == runtime_local_ref;
}

fn is_list_word(word: i64) bool {
    // [] (the empty list) is represented as the nil atom, matching BEAM.
    return word == nil_word or is_list_cell_word(word);
}

fn is_list_cell_word(word: i64) bool {
    return word_tag(word) == tag_list and
        (@as(usize, @bitCast(word)) & ~tag_mask) != 0;
}

fn list_len(list: i64) usize {
    var current = list;
    var count: usize = 0;
    while (is_list_cell_word(current)) {
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

fn fun_has_arity(fun: i64) bool {
    return (@as(u64, @bitCast(fun_words(fun)[1])) & fun_arity_marker) != 0;
}

fn fun_has_signature(fun: i64) bool {
    return (@as(u64, @bitCast(fun_words(fun)[1])) & fun_signature_marker) != 0;
}

fn fun_env_len(fun: i64) usize {
    const header: u64 = @bitCast(fun_words(fun)[1]);
    return @intCast(header & ~(fun_arity_marker | fun_signature_marker));
}

fn fun_env_offset(fun: i64) usize {
    return if (fun_has_signature(fun)) 4 else if (fun_has_arity(fun)) 3 else 2;
}

fn boxed_words(word: i64) [*]const i64 {
    return @ptrFromInt(@as(usize, @bitCast(word)) & ~tag_mask);
}

fn boxed_kind(word: i64) i64 {
    return boxed_words(word)[0];
}

fn is_boxed_float(word: i64) bool {
    return word_tag(word) == tag_float and runtime_local_kind(word) == null and boxed_kind(word) == boxed_float_kind;
}

fn is_bigint(word: i64) bool {
    return word_tag(word) == tag_float and runtime_local_kind(word) == null and boxed_kind(word) == boxed_bigint_kind;
}

fn float_bits(float: i64) u64 {
    return @bitCast(boxed_words(float)[1]);
}

fn bigint_len(word: i64) usize {
    return @intCast(boxed_words(word)[1]);
}

fn bigint_bytes(word: i64) [*]const u8 {
    return @ptrFromInt((@as(usize, @bitCast(word)) & ~tag_mask) + 2 * @sizeOf(i64));
}

fn bigint_eq(left: i64, right: i64) bool {
    const left_len = bigint_len(left);
    if (left_len != bigint_len(right)) return false;
    return std.mem.eql(u8, bigint_bytes(left)[0..left_len], bigint_bytes(right)[0..left_len]);
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
    exit_kind: i64 = 0,
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

const LifecyclePhase = enum(u8) {
    idle,
    executing,
    exporting,
    destroying,
};

const Runtime = struct {
    lifecycle_lock: RuntimeMutex = .{},
    lifecycle_phase: LifecyclePhase = .idle,
    execution_handle: i64 = 0,
    execution_owner: usize = 0,
    execution_participants: u32 = 0,
    execution_initialized: bool = false,
    execution_epoch: u64 = 0,
    heap_lock: RuntimeMutex = .{},
    scheduler_lock: RuntimeMutex = .{},
    counter_lock: RuntimeMutex = .{},
    callback_lock: RuntimeMutex = .{},
    atom_lock: RuntimeMutex = .{},
    configured_workers: std.atomic.Value(u32) = .init(1),
    active_actors: std.atomic.Value(u32) = .init(0),
    max_active_actors: std.atomic.Value(u32) = .init(0),
    migrations: std.atomic.Value(u64) = .init(0),
    entered_workers: std.atomic.Value(u32) = .init(0),
    outstanding_results: std.atomic.Value(u32) = .init(0),
    outstanding_terms: std.atomic.Value(u32) = .init(0),
    allocation_failed: std.atomic.Value(bool) = .init(false),
    arena_chunks: [arena_chunk_cap]ArenaChunk = [_]ArenaChunk{.{}} ** arena_chunk_cap,
    arena_chunk_count: usize = 0,
    arena_capacity_words: usize = 0,
    arena_used_words: std.atomic.Value(usize) = .init(0),
    arena_limit_bytes: usize = arena_hard_limit_bytes,
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
    dynamic_atom_names: [dynamic_atom_cap]i64 = [_]i64{0} ** dynamic_atom_cap,
    dynamic_atom_count: usize = 0,

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

/// Test-only runtime census used by the actor soak runner. The function that
/// produces this value is compile-time disabled in non-test builds, keeping
/// the stress oracle out of the production ABI and Release artifacts.
pub const RuntimeSoakSnapshot = struct {
    lifecycle_phase: u8,
    execution_owner: usize,
    execution_participants: u32,
    execution_initialized: bool,
    execution_epoch: u64,
    outstanding_results: u32,
    outstanding_terms: u32,
    process_count: usize,
    process_capacity: usize,
    free_count: usize,
    runnable: usize,
    waiting: usize,
    done: usize,
    exited: usize,
    owned: usize,
    mailbox_messages: usize,
    configured_workers: u32,
    max_active_actors: u32,
    migrations: u64,
    arena_chunks: usize,
    arena_bytes: usize,
    arena_high_water: usize,
    oom: bool,
};

pub fn runtimeSoakSnapshot(handle: i64) ?RuntimeSoakSnapshot {
    if (comptime !builtin.is_test) return null;

    runtime_lock.lock();
    defer runtime_lock.unlock();
    const slot = runtime_slot_locked(handle) orelse return null;
    const instance = slot.runtime.?;

    instance.lifecycle_lock.lock();
    var snapshot = RuntimeSoakSnapshot{
        .lifecycle_phase = @intFromEnum(instance.lifecycle_phase),
        .execution_owner = instance.execution_owner,
        .execution_participants = instance.execution_participants,
        .execution_initialized = instance.execution_initialized,
        .execution_epoch = instance.execution_epoch,
        .outstanding_results = instance.outstanding_results.load(.acquire),
        .outstanding_terms = instance.outstanding_terms.load(.acquire),
        .process_count = 0,
        .process_capacity = 0,
        .free_count = 0,
        .runnable = 0,
        .waiting = 0,
        .done = 0,
        .exited = 0,
        .owned = 0,
        .mailbox_messages = 0,
        .configured_workers = instance.configured_workers.load(.acquire),
        .max_active_actors = instance.max_active_actors.load(.acquire),
        .migrations = instance.migrations.load(.acquire),
        .arena_chunks = 0,
        .arena_bytes = 0,
        .arena_high_water = 0,
        .oom = instance.allocation_failed.load(.acquire),
    };
    instance.lifecycle_lock.unlock();

    instance.scheduler_lock.lock();
    snapshot.process_count = instance.process_count;
    snapshot.process_capacity = instance.processes.len;
    snapshot.free_count = instance.free_count;
    for (instance.processes[0..instance.process_count]) |proc| {
        proc.state_lock.lock();
        switch (proc.status) {
            .runnable => snapshot.runnable += 1,
            .waiting => snapshot.waiting += 1,
            .done => snapshot.done += 1,
            .exited => snapshot.exited += 1,
        }
        proc.state_lock.unlock();
        if (proc.owner.load(.acquire) != 0) snapshot.owned += 1;
        snapshot.mailbox_messages += proc.mailbox.count();
    }
    instance.scheduler_lock.unlock();

    instance.heap_lock.lock();
    snapshot.arena_chunks = instance.arena_chunk_count;
    snapshot.arena_bytes = instance.arena_capacity_words * @sizeOf(i64);
    snapshot.arena_high_water = instance.arena_used_words.load(.acquire) * @sizeOf(i64);
    instance.heap_lock.unlock();
    return snapshot;
}

pub fn runtimeSoakForceOom(handle: i64) bool {
    if (comptime !builtin.is_test) return false;
    if (active_runtime_handle != handle or active_runtime == null) return false;
    return alloc_words(arena_hard_limit_words + 1) == null;
}

pub fn exportedSoakBytes() usize {
    if (comptime !builtin.is_test) return 0;
    exported_lock.lock();
    defer exported_lock.unlock();
    var total: usize = 0;
    for (exported_slots) |slot| {
        if (slot.bytes) |bytes| total += bytes.len;
    }
    return total;
}

// Deterministic lifecycle interleavings are controlled by one test-only gate.
// `builtin.is_test` is a compile-time constant, so calls and storage disappear
// entirely from shared/static Release builds.
const LifecycleTestPoint = enum(u8) {
    none,
    runtime_leave_committed,
    result_export_committed,
    term_export_committed,
    result_destroy_snapshotted,
    term_destroy_snapshotted,
    import_validated,
};

const LifecycleSnapshot = struct {
    phase: LifecyclePhase,
    execution_handle: i64,
    owner: usize,
    participants: u32,
    initialized: bool,
    execution_epoch: u64,
    results: u32,
    terms: u32,

    fn capture(instance: *Runtime) LifecycleSnapshot {
        return .{
            .phase = instance.lifecycle_phase,
            .execution_handle = instance.execution_handle,
            .owner = instance.execution_owner,
            .participants = instance.execution_participants,
            .initialized = instance.execution_initialized,
            .execution_epoch = instance.execution_epoch,
            .results = instance.outstanding_results.load(.acquire),
            .terms = instance.outstanding_terms.load(.acquire),
        };
    }
};

const LifecycleTestGate = struct {
    point: std.atomic.Value(LifecycleTestPoint) = .init(.none),
    arrived: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    snapshot: LifecycleSnapshot = undefined,
    case_name: []const u8 = "unarmed",
    seed: u64 = 0,

    fn arm(self: *LifecycleTestGate, point: LifecycleTestPoint, case_name: []const u8, seed: u64) void {
        std.debug.assert(self.point.load(.acquire) == .none);
        self.case_name = case_name;
        self.seed = seed;
        self.snapshot = undefined;
        self.released.store(false, .release);
        self.arrived.store(false, .release);
        self.point.store(point, .release);
    }

    fn reach(self: *LifecycleTestGate, point: LifecycleTestPoint, instance: *Runtime) void {
        if (self.point.load(.acquire) != point) return;
        self.snapshot = LifecycleSnapshot.capture(instance);
        self.arrived.store(true, .release);
        while (!self.released.load(.acquire)) std.Thread.yield() catch {};
    }

    fn waitArrived(self: *LifecycleTestGate) bool {
        for (0..10_000_000) |_| {
            if (self.arrived.load(.acquire)) return true;
            std.Thread.yield() catch {};
        }
        std.debug.print(
            "lifecycle race timeout: case={s} seed={d} point={s}\n",
            .{ self.case_name, self.seed, @tagName(self.point.load(.acquire)) },
        );
        return false;
    }

    fn release(self: *LifecycleTestGate) void {
        self.released.store(true, .release);
    }

    fn disarm(self: *LifecycleTestGate) void {
        self.release();
        self.point.store(.none, .release);
        self.arrived.store(false, .release);
    }
};

const LifecycleTestState = struct {
    var gate: LifecycleTestGate = .{};
};

inline fn lifecycleTestReach(point: LifecycleTestPoint, instance: *Runtime) void {
    if (comptime builtin.is_test) LifecycleTestState.gate.reach(point, instance);
}

// A separate test-only barrier pauses a graph operation after global registry
// locks have been released. Tests can then require an unrelated runtime to
// finish a complete lifecycle before the paused operation is allowed to
// continue, proving progress without relying on wall-clock timing.
const CrossRuntimeTestPoint = enum(u8) {
    none,
    export_traversal,
    import_decode,
};

const CrossRuntimeTestGate = struct {
    point: std.atomic.Value(CrossRuntimeTestPoint) = .init(.none),
    arrived: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    target: ?*Runtime = null,
    case_name: []const u8 = "unarmed",
    seed: u64 = 0,

    fn arm(self: *@This(), point: CrossRuntimeTestPoint, target: *Runtime, case_name: []const u8, seed: u64) void {
        std.debug.assert(self.point.load(.acquire) == .none);
        self.target = target;
        self.case_name = case_name;
        self.seed = seed;
        self.released.store(false, .release);
        self.arrived.store(false, .release);
        self.point.store(point, .release);
    }

    fn reach(self: *@This(), point: CrossRuntimeTestPoint, target: *Runtime) void {
        if (self.point.load(.acquire) != point or self.target != target) return;
        self.arrived.store(true, .release);
        while (!self.released.load(.acquire)) std.Thread.yield() catch {};
    }

    fn waitArrived(self: *@This()) bool {
        for (0..10_000_000) |_| {
            if (self.arrived.load(.acquire)) return true;
            std.Thread.yield() catch {};
        }
        std.debug.print(
            "cross-runtime timeout: case={s} seed={d} point={s}\n",
            .{ self.case_name, self.seed, @tagName(self.point.load(.acquire)) },
        );
        return false;
    }

    fn release(self: *@This()) void {
        self.released.store(true, .release);
    }

    fn disarm(self: *@This()) void {
        self.release();
        self.point.store(.none, .release);
        self.arrived.store(false, .release);
        self.target = null;
    }
};

const CrossRuntimeTestState = struct {
    var gate: CrossRuntimeTestGate = .{};
};

inline fn crossRuntimeTestReach(point: CrossRuntimeTestPoint, instance: *Runtime) void {
    if (comptime builtin.is_test) CrossRuntimeTestState.gate.reach(point, instance);
}

// Explicit runtimes are addressed through generation-checked slots.  The C
// ABI never treats a host-provided integer as a pointer, so a stale handle is
// rejected before any runtime memory is touched.
const runtime_slot_cap: usize = 4096;

const RuntimeSlot = struct {
    runtime: ?*Runtime = null,
    generation: u32 = 1,
};

var runtime_lock: RuntimeMutex = .{};
var runtime_slots: [runtime_slot_cap]RuntimeSlot = [_]RuntimeSlot{.{}} ** runtime_slot_cap;
var runtime_cursor: usize = 0;

fn opaque_handle(index: usize, generation: u32) i64 {
    const bits = (@as(u64, generation) << 32) | @as(u64, @intCast(index + 1));
    return @bitCast(bits);
}

fn handle_index_generation(handle: i64, cap: usize) ?struct { index: usize, generation: u32 } {
    const bits: u64 = @bitCast(handle);
    const encoded_index: u32 = @truncate(bits);
    if (encoded_index == 0) return null;
    const index = @as(usize, encoded_index - 1);
    if (index >= cap) return null;
    return .{ .index = index, .generation = @truncate(bits >> 32) };
}

fn runtime_slot_locked(handle: i64) ?*RuntimeSlot {
    const decoded = handle_index_generation(handle, runtime_slot_cap) orelse return null;
    const slot = &runtime_slots[decoded.index];
    if (slot.runtime == null or slot.generation != decoded.generation) return null;
    return slot;
}

fn invalidate_runtime_slot_locked(handle: i64) ?*Runtime {
    const slot = runtime_slot_locked(handle) orelse return null;
    const instance = slot.runtime.?;
    slot.runtime = null;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    return instance;
}

// Host result handles keep an execution runtime alive while a JIT or AOT host
// copies the returned term out of the arena. The generation makes a handle
// deterministic to reject after its slot has been recycled; callers never
// dereference an address supplied by the host.
const result_slot_cap: usize = 4096;

const ResultSlot = struct {
    runtime: ?*Runtime = null,
    runtime_handle: i64 = 0,
    word: i64 = 0,
    generation: u32 = 1,
};

var result_lock: RuntimeMutex = .{};
var result_slots: [result_slot_cap]ResultSlot = [_]ResultSlot{.{}} ** result_slot_cap;
var result_cursor: usize = 0;

const exported_slot_cap: usize = 4096;
const exported_max_bytes: usize = 16 * 1024 * 1024;
const exported_max_depth: usize = 256;
const exported_magic = [_]u8{ 'B', 'T', 'A', 1 };

const ExportedSlot = struct {
    bytes: ?[]u8 = null,
    refs: u32 = 0,
    generation: u32 = 1,
};

var exported_lock: RuntimeMutex = .{};
var exported_slots: [exported_slot_cap]ExportedSlot = [_]ExportedSlot{.{}} ** exported_slot_cap;
var exported_cursor: usize = 0;

fn exported_slot_locked(handle: i64) ?*ExportedSlot {
    const decoded = handle_index_generation(handle, exported_slot_cap) orelse return null;
    const slot = &exported_slots[decoded.index];
    if (slot.bytes == null or slot.generation != decoded.generation) return null;
    return slot;
}

fn retain_exported_bytes(handle: i64) error{ Invalid, Limit }![]const u8 {
    exported_lock.lock();
    defer exported_lock.unlock();
    const slot = exported_slot_locked(handle) orelse return error.Invalid;
    if (slot.refs == std.math.maxInt(u32)) return error.Limit;
    slot.refs += 1;
    return slot.bytes.?;
}

fn release_exported_locked(slot: *ExportedSlot) void {
    slot.refs -= 1;
    if (slot.refs == 0) {
        std.heap.page_allocator.free(slot.bytes.?);
        slot.bytes = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
    }
}

fn release_exported_retain(handle: i64) void {
    exported_lock.lock();
    defer exported_lock.unlock();
    const slot = exported_slot_locked(handle) orelse return;
    release_exported_locked(slot);
}

const term_slot_cap: usize = 4096;

const TermSlot = struct {
    runtime: ?*Runtime = null,
    runtime_handle: i64 = 0,
    word: i64 = 0,
    root_scalar: bool = false,
    generation: u32 = 1,
};

var term_lock: RuntimeMutex = .{};
var term_slots: [term_slot_cap]TermSlot = [_]TermSlot{.{}} ** term_slot_cap;
var term_cursor: usize = 0;

fn term_slot_locked(handle: i64) ?*TermSlot {
    const decoded = handle_index_generation(handle, term_slot_cap) orelse return null;
    const slot = &term_slots[decoded.index];
    if (slot.runtime == null or slot.generation != decoded.generation) return null;
    return slot;
}

fn result_handle(index: usize, generation: u32) i64 {
    return opaque_handle(index, generation);
}

fn result_slot_locked(handle: i64) ?*ResultSlot {
    const decoded = handle_index_generation(handle, result_slot_cap) orelse return null;
    const slot = &result_slots[decoded.index];
    if (slot.runtime == null or slot.generation != decoded.generation) return null;
    return slot;
}

const ResultMemorySnapshot = struct {
    arena_capacity_bytes: usize,
    arena_chunks: usize,
    arena_high_water_bytes: usize,
    arena_limit_bytes: usize,
    oom: bool,
};

fn result_memory_snapshot(handle: i64) ?ResultMemorySnapshot {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return null;
    const instance = slot.runtime.?;
    instance.heap_lock.lock();
    defer instance.heap_lock.unlock();
    return .{
        .arena_capacity_bytes = instance.arena_capacity_words * @sizeOf(i64),
        .arena_chunks = instance.arena_chunk_count,
        .arena_high_water_bytes = instance.arena_used_words.load(.acquire) * @sizeOf(i64),
        .arena_limit_bytes = instance.arena_limit_bytes,
        .oom = instance.allocation_failed.load(.acquire),
    };
}

fn runtime_owns_word(instance: *Runtime, word: i64) bool {
    const tag = word_tag(word);
    if (tag < tag_tuple or tag > tag_float) return false;
    if (tag == tag_runtime_local and runtime_local_kind(word) != null) return false;
    const address = @as(usize, @bitCast(word)) & ~tag_mask;
    for (instance.arena_chunks[0..instance.arena_chunk_count]) |chunk| {
        const words = chunk.words orelse continue;
        const start = @intFromPtr(words.ptr);
        const end = start + chunk.bump * @sizeOf(i64);
        if (address >= start and address < end) return true;
    }
    return false;
}

fn runtime_owns_bytes(instance: *Runtime, address: usize, byte_count: usize) bool {
    const requested_end = std.math.add(usize, address, byte_count) catch return false;
    for (instance.arena_chunks[0..instance.arena_chunk_count]) |chunk| {
        const words = chunk.words orelse continue;
        const start = @intFromPtr(words.ptr);
        const end = start + chunk.bump * @sizeOf(i64);
        if (address >= start and requested_end <= end) return true;
    }
    return false;
}

fn result_term_kind_locked(slot: *ResultSlot, word: i64) i64 {
    const tag = word_tag(word);
    if (tag == tag_int or tag == tag_atom) return @intCast(tag);
    if (slot.runtime) |instance| {
        if (runtime_owns_word(instance, word)) {
            if (tag == tag_float and is_bigint(word)) return result_kind_bigint;
            return @intCast(tag);
        }
    }
    return -1;
}

threadlocal var active_runtime: ?*Runtime = null;
threadlocal var active_runtime_handle: i64 = 0;
threadlocal var worker_runtime: ?*Runtime = null;
threadlocal var worker_runtime_handle: i64 = 0;
threadlocal var worker_execution_epoch: u64 = 0;
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

fn current_thread_id() usize {
    return @intCast(std.Thread.getCurrentId());
}

fn is_execution_owner_locked(instance: *Runtime, handle: i64) bool {
    return instance.lifecycle_phase == .executing and
        instance.execution_handle == handle and
        instance.execution_owner == current_thread_id() and
        active_runtime == instance and
        active_runtime_handle == handle;
}

fn clear_runtime_thread_state(instance: *Runtime) void {
    if (arena_cached_runtime == instance) {
        arena_cached_runtime = null;
        arena_cached_epoch = 0;
        arena_cached_chunk = arena_chunk_cap;
    }
    active_runtime = null;
    active_runtime_handle = 0;
    current_process = 0;
    current_process_ptr = null;
}

fn worker_join(instance: *Runtime, handle: i64, epoch: u64) bool {
    if (active_runtime_handle != 0 or worker_runtime != null) return false;
    instance.lifecycle_lock.lock();
    defer instance.lifecycle_lock.unlock();
    if (instance.lifecycle_phase != .executing or
        instance.execution_handle != handle or
        instance.execution_epoch != epoch or
        instance.execution_participants == std.math.maxInt(u32)) return false;
    instance.execution_participants += 1;
    instance.entered_workers.store(instance.execution_participants, .release);
    worker_runtime = instance;
    worker_runtime_handle = handle;
    worker_execution_epoch = epoch;
    active_runtime = instance;
    return true;
}

fn worker_leave() bool {
    const instance = worker_runtime orelse return false;
    instance.lifecycle_lock.lock();
    defer instance.lifecycle_lock.unlock();
    if (instance.lifecycle_phase != .executing or
        instance.execution_handle != worker_runtime_handle or
        instance.execution_epoch != worker_execution_epoch or
        instance.execution_participants <= 1) return false;
    instance.execution_participants -= 1;
    instance.entered_workers.store(instance.execution_participants, .release);
    worker_runtime = null;
    worker_runtime_handle = 0;
    worker_execution_epoch = 0;
    clear_runtime_thread_state(instance);
    arena_worker_id = 0;
    return true;
}

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
    instance.arena_used_words.store(0, .release);
    instance.allocation_failed.store(false, .release);
}

fn reserve_arena_words(instance: *Runtime, count: usize) bool {
    const limit_words = instance.arena_limit_bytes / @sizeOf(i64);
    var used = instance.arena_used_words.load(.acquire);
    while (true) {
        if (used > limit_words or count > limit_words - used) {
            instance.allocation_failed.store(true, .release);
            return false;
        }
        used = instance.arena_used_words.cmpxchgWeak(
            used,
            used + count,
            .acq_rel,
            .acquire,
        ) orelse return true;
    }
}

fn release_arena_words(instance: *Runtime, count: usize) void {
    _ = instance.arena_used_words.fetchSub(count, .acq_rel);
}

fn alloc_words(count: usize) ?[*]i64 {
    const instance = runtime();
    if (!reserve_arena_words(instance, count)) return null;

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

    if (instance.arena_chunk_count >= arena_chunk_cap) {
        release_arena_words(instance, count);
        instance.allocation_failed.store(true, .release);
        return null;
    }
    const word_count = @max(count, arena_chunk_words);
    if (instance.arena_capacity_words + word_count > arena_hard_limit_words) {
        release_arena_words(instance, count);
        instance.allocation_failed.store(true, .release);
        return null;
    }
    const words = std.heap.page_allocator.alloc(i64, word_count) catch {
        release_arena_words(instance, count);
        instance.allocation_failed.store(true, .release);
        return null;
    };
    index = instance.arena_chunk_count;
    instance.arena_chunk_count += 1;
    instance.arena_capacity_words += word_count;
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

fn tuple2(a: i64, b: i64) i64 {
    const words = alloc_words(3) orelse return nil_word;
    words[0] = 2;
    words[1] = a;
    words[2] = b;
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
pub fn ex_term_runtime_create() callconv(.c) i64 {
    const instance = create_runtime();
    runtime_lock.lock();
    defer runtime_lock.unlock();
    var offset: usize = 0;
    while (offset < runtime_slot_cap) : (offset += 1) {
        const index = (runtime_cursor + offset) % runtime_slot_cap;
        const slot = &runtime_slots[index];
        if (slot.runtime == null) {
            slot.runtime = instance;
            runtime_cursor = (index + 1) % runtime_slot_cap;
            return opaque_handle(index, slot.generation);
        }
    }
    instance.deinit();
    return 0;
}

/// Binds an execution instance to the calling worker thread.
pub fn ex_term_runtime_enter(handle: i64) callconv(.c) i64 {
    if (active_runtime_handle == handle and active_runtime != null) return 0;
    if (active_runtime_handle != 0 or worker_runtime != null) return -2;
    runtime_lock.lock();
    defer runtime_lock.unlock();
    const slot = runtime_slot_locked(handle) orelse return -1;
    const instance = slot.runtime.?;
    instance.lifecycle_lock.lock();
    defer instance.lifecycle_lock.unlock();
    if (instance.lifecycle_phase != .idle or
        instance.outstanding_results.load(.acquire) != 0 or
        instance.outstanding_terms.load(.acquire) != 0) return -2;
    if (instance.execution_epoch == std.math.maxInt(u64)) return -2;
    instance.execution_epoch += 1;
    instance.lifecycle_phase = .executing;
    instance.execution_handle = handle;
    instance.execution_owner = current_thread_id();
    instance.execution_participants = 1;
    instance.execution_initialized = false;
    instance.entered_workers.store(1, .release);
    active_runtime = instance;
    active_runtime_handle = handle;
    current_process = 0;
    current_process_ptr = null;
    return 0;
}

/// Configures the per-execution arena quota while the runtime is idle.
/// Returns -1 for a stale handle, -2 while active/pinned, and -3 for an
/// invalid byte limit. The allocator accounts in whole i64 words, so a
/// non-aligned byte limit is enforced by rounding its usable portion down.
pub fn ex_term_runtime_set_arena_limit(handle: i64, bytes: i64) callconv(.c) i64 {
    if (bytes < 0) return -3;
    const limit: usize = @intCast(bytes);
    if (limit > arena_hard_limit_bytes) return -3;
    runtime_lock.lock();
    defer runtime_lock.unlock();
    const slot = runtime_slot_locked(handle) orelse return -1;
    const instance = slot.runtime.?;
    instance.lifecycle_lock.lock();
    defer instance.lifecycle_lock.unlock();
    if (instance.lifecycle_phase != .idle or
        instance.outstanding_results.load(.acquire) != 0 or
        instance.outstanding_terms.load(.acquire) != 0) return -2;
    instance.arena_limit_bytes = limit;
    return 0;
}

/// Leaves the explicit instance and restores the thread-owned compatibility
/// runtime on the next ABI call.
pub fn ex_term_runtime_leave() callconv(.c) i64 {
    if (active_runtime_handle == 0) return -1;
    const instance = active_runtime orelse return -1;
    instance.lifecycle_lock.lock();
    if (!is_execution_owner_locked(instance, active_runtime_handle)) {
        instance.lifecycle_lock.unlock();
        return -1;
    }
    if (instance.execution_participants != 1) {
        instance.lifecycle_lock.unlock();
        return -2;
    }
    instance.lifecycle_phase = .idle;
    instance.execution_handle = 0;
    instance.execution_owner = 0;
    instance.execution_participants = 0;
    instance.execution_initialized = false;
    instance.entered_workers.store(0, .release);
    instance.lifecycle_lock.unlock();
    lifecycleTestReach(.runtime_leave_committed, instance);
    clear_runtime_thread_state(instance);
    return 0;
}

/// Releases an execution instance. All workers must leave it before destroy.
pub fn ex_term_runtime_destroy(handle: i64) callconv(.c) i64 {
    runtime_lock.lock();
    const slot = runtime_slot_locked(handle) orelse {
        runtime_lock.unlock();
        return -1;
    };
    const instance = slot.runtime.?;
    instance.lifecycle_lock.lock();
    if (instance.outstanding_results.load(.acquire) != 0 or
        instance.outstanding_terms.load(.acquire) != 0)
    {
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return -2;
    }
    if (instance.lifecycle_phase != .idle) {
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return -2;
    }
    instance.lifecycle_phase = .destroying;
    _ = invalidate_runtime_slot_locked(handle);
    instance.lifecycle_lock.unlock();
    runtime_lock.unlock();
    if (owned_runtime == instance) owned_runtime = null;
    instance.deinit();
    return 0;
}

pub fn ex_term_runtime_arena_bytes(handle: i64) callconv(.c) i64 {
    runtime_lock.lock();
    defer runtime_lock.unlock();
    const slot = runtime_slot_locked(handle) orelse return -1;
    const instance = slot.runtime.?;
    return @intCast(instance.arena_capacity_words * @sizeOf(i64));
}

pub fn ex_term_runtime_arena_chunks(handle: i64) callconv(.c) i64 {
    runtime_lock.lock();
    defer runtime_lock.unlock();
    const slot = runtime_slot_locked(handle) orelse return -1;
    const instance = slot.runtime.?;
    return @intCast(instance.arena_chunk_count);
}

pub fn ex_term_runtime_arena_high_water(handle: i64) callconv(.c) i64 {
    runtime_lock.lock();
    defer runtime_lock.unlock();
    const slot = runtime_slot_locked(handle) orelse return -1;
    const instance = slot.runtime.?;
    return @intCast(instance.arena_used_words.load(.acquire) * @sizeOf(i64));
}

pub fn ex_term_runtime_arena_limit(handle: i64) callconv(.c) i64 {
    runtime_lock.lock();
    defer runtime_lock.unlock();
    const slot = runtime_slot_locked(handle) orelse return -1;
    return @intCast(slot.runtime.?.arena_limit_bytes);
}

pub fn ex_term_runtime_oom(handle: i64) callconv(.c) i64 {
    runtime_lock.lock();
    defer runtime_lock.unlock();
    const slot = runtime_slot_locked(handle) orelse return -1;
    const instance = slot.runtime.?;
    return if (instance.allocation_failed.load(.acquire)) 1 else 0;
}

/// Pins a completed execution result and transfers ownership of its runtime
/// to the returned opaque handle. Zero means the bounded registry is full.
pub fn ex_term_result_create(runtime_handle: i64, word: i64) callconv(.c) i64 {
    if (active_runtime_handle != runtime_handle) return -1;
    const instance = active_runtime orelse return -1;
    instance.lifecycle_lock.lock();
    defer instance.lifecycle_lock.unlock();
    if (!is_execution_owner_locked(instance, runtime_handle) or
        instance.execution_participants != 1 or
        !instance.execution_initialized) return -1;
    if (instance.outstanding_results.load(.acquire) != 0) {
        return -3;
    }
    if (word == nil_word and instance.allocation_failed.load(.acquire)) {
        return -2;
    }
    result_lock.lock();

    var offset: usize = 0;
    while (offset < result_slot_cap) : (offset += 1) {
        const index = (result_cursor + offset) % result_slot_cap;
        const slot = &result_slots[index];
        if (slot.runtime == null) {
            slot.runtime = instance;
            slot.runtime_handle = runtime_handle;
            slot.word = word;
            _ = instance.outstanding_results.fetchAdd(1, .acq_rel);
            result_cursor = (index + 1) % result_slot_cap;
            result_lock.unlock();
            return result_handle(index, slot.generation);
        }
    }
    result_lock.unlock();
    return 0;
}

/// Releases a result and the execution runtime it owns.
pub fn ex_term_result_destroy(handle: i64) callconv(.c) i64 {
    result_lock.lock();
    const initial = result_slot_locked(handle) orelse {
        result_lock.unlock();
        return -1;
    };
    const instance = initial.runtime.?;
    const runtime_handle = initial.runtime_handle;
    result_lock.unlock();
    lifecycleTestReach(.result_destroy_snapshotted, instance);

    runtime_lock.lock();
    const runtime_slot = runtime_slot_locked(runtime_handle) orelse {
        runtime_lock.unlock();
        return -1;
    };
    if (runtime_slot.runtime.? != instance) {
        runtime_lock.unlock();
        return -1;
    }
    instance.lifecycle_lock.lock();
    result_lock.lock();
    const slot = result_slot_locked(handle) orelse {
        result_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return -1;
    };
    if (slot.runtime.? != instance or slot.runtime_handle != runtime_handle) {
        result_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return -1;
    }
    if (instance.lifecycle_phase != .idle or
        instance.outstanding_terms.load(.acquire) != 0)
    {
        result_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return -2;
    }
    instance.lifecycle_phase = .destroying;
    slot.runtime = null;
    slot.runtime_handle = 0;
    slot.word = 0;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    _ = instance.outstanding_results.fetchSub(1, .acq_rel);
    _ = invalidate_runtime_slot_locked(runtime_handle);
    result_lock.unlock();
    instance.lifecycle_lock.unlock();
    runtime_lock.unlock();
    if (owned_runtime == instance) owned_runtime = null;
    instance.deinit();
    return 0;
}

pub fn ex_term_result_arena_capacity_bytes(handle: i64) callconv(.c) i64 {
    const snapshot = result_memory_snapshot(handle) orelse return -1;
    return @intCast(snapshot.arena_capacity_bytes);
}

pub fn ex_term_result_arena_chunks(handle: i64) callconv(.c) i64 {
    const snapshot = result_memory_snapshot(handle) orelse return -1;
    return @intCast(snapshot.arena_chunks);
}

pub fn ex_term_result_arena_high_water(handle: i64) callconv(.c) i64 {
    const snapshot = result_memory_snapshot(handle) orelse return -1;
    return @intCast(snapshot.arena_high_water_bytes);
}

pub fn ex_term_result_arena_limit(handle: i64) callconv(.c) i64 {
    const snapshot = result_memory_snapshot(handle) orelse return -1;
    return @intCast(snapshot.arena_limit_bytes);
}

pub fn ex_term_result_oom(handle: i64) callconv(.c) i64 {
    const snapshot = result_memory_snapshot(handle) orelse return -1;
    return if (snapshot.oom) 1 else 0;
}

/// Classifies the root. Untagged scalar returns remain scalar even when their
/// low bits happen to resemble a heap tag.
pub fn ex_term_result_root_kind(handle: i64) callconv(.c) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    if (runtime_owns_word(slot.runtime.?, slot.word)) return result_term_kind_locked(slot, slot.word);
    if (dynamic_atom_index(slot.word) != null) return tag_atom;
    if (runtime_local_kind(slot.word) != null) return -1;
    return 0;
}

pub fn ex_term_result_root_word(handle: i64) callconv(.c) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    return slot.word;
}

pub fn ex_term_result_term_kind(handle: i64, word: i64) callconv(.c) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    return result_term_kind_locked(slot, word);
}

/// Returns the runtime-owned binary name for a dynamic atom, or nil for a
/// literal, stale, foreign, or otherwise invalid atom word.
pub fn ex_term_result_atom_name(handle: i64, word: i64) callconv(.c) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return nil_word;
    const index = dynamic_atom_index(word) orelse return nil_word;
    const instance = slot.runtime.?;
    instance.atom_lock.lock();
    defer instance.atom_lock.unlock();
    if (index >= instance.dynamic_atom_count) return nil_word;
    return instance.dynamic_atom_names[index];
}

pub fn ex_term_result_term_length(handle: i64, word: i64) callconv(.c) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    const kind = result_term_kind_locked(slot, word);
    return switch (kind) {
        tag_tuple => @intCast(tuple_len(word)),
        tag_list => @intCast(list_len(word)),
        tag_map => @intCast(map_len(word)),
        tag_binary => @intCast(binary_len(word)),
        tag_fun => @intCast(fun_env_len(word)),
        tag_float => 1,
        result_kind_bigint => @intCast(bigint_len(word)),
        else => -1,
    };
}

pub fn ex_term_result_term_get(handle: i64, word: i64, index_word: i64) callconv(.c) i64 {
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
        tag_float => if (index == 0) @bitCast(float_bits(word)) else -1,
        result_kind_bigint => if (index < bigint_len(word)) bigint_bytes(word)[index] else -1,
        tag_fun => if (index == 0)
            fun_words(word)[0]
        else if (index <= fun_env_len(word))
            fun_words(word)[fun_env_offset(word) + index - 1]
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

const CodecError = error{ Unsupported, Invalid, Limit };
const codec_scalar: u8 = 0;
const codec_int: u8 = 1;
const codec_atom: u8 = 2;
const codec_tuple: u8 = 3;
const codec_cons: u8 = 4;
const codec_map: u8 = 5;
const codec_binary: u8 = 6;
const codec_float: u8 = 7;
const codec_bigint: u8 = 8;

fn checkedAdd(a: usize, b: usize) CodecError!usize {
    const value = std.math.add(usize, a, b) catch return error.Limit;
    if (value > exported_max_bytes) return error.Limit;
    return value;
}

fn checkedMul(a: usize, b: usize) CodecError!usize {
    return std.math.mul(usize, a, b) catch return error.Limit;
}

fn containerLength(instance: *Runtime, word: i64, element_words: usize) CodecError!usize {
    const address = @as(usize, @bitCast(word)) & ~tag_mask;
    if (!runtime_owns_bytes(instance, address, @sizeOf(i64))) return error.Invalid;
    const header: *const i64 = @ptrFromInt(address);
    if (header.* < 0) return error.Invalid;
    const len: usize = @intCast(header.*);
    const payload_words = try checkedMul(len, element_words);
    const total_words = try checkedAdd(payload_words, 1);
    const total_bytes = try checkedMul(total_words, @sizeOf(i64));
    if (!runtime_owns_bytes(instance, address, total_bytes)) return error.Invalid;
    return len;
}

fn encodedTermSize(instance: *Runtime, word: i64, root_scalar: bool, depth: usize) CodecError!usize {
    if (depth > exported_max_depth) return error.Limit;
    if (root_scalar) return 1 + @sizeOf(i64);
    return switch (word_tag(word)) {
        tag_int => 1 + @sizeOf(i64),
        tag_atom => if (dynamic_atom_index(word) == null)
            1 + @sizeOf(i64)
        else
            error.Unsupported,
        tag_tuple => blk: {
            const len = try containerLength(instance, word, 1);
            var size: usize = 1 + @sizeOf(u32);
            for (tuple_elems(word)[0..len]) |child| {
                size = try checkedAdd(size, try encodedTermSize(instance, child, false, depth + 1));
            }
            break :blk size;
        },
        tag_list => blk: {
            const address = @as(usize, @bitCast(word)) & ~tag_mask;
            if (!runtime_owns_bytes(instance, address, 2 * @sizeOf(i64))) return error.Invalid;
            const cell = list_cell(word);
            var size: usize = 1;
            size = try checkedAdd(size, try encodedTermSize(instance, cell[0], false, depth + 1));
            size = try checkedAdd(size, try encodedTermSize(instance, cell[1], false, depth + 1));
            break :blk size;
        },
        tag_map => blk: {
            const len = try containerLength(instance, word, 2);
            var size: usize = 1 + @sizeOf(u32);
            for (map_entries(word)[0 .. len * 2]) |child| {
                size = try checkedAdd(size, try encodedTermSize(instance, child, false, depth + 1));
            }
            break :blk size;
        },
        tag_binary => blk: {
            const address = @as(usize, @bitCast(word)) & ~tag_mask;
            if (!runtime_owns_bytes(instance, address, @sizeOf(i64))) return error.Invalid;
            const raw_len = @as(*const i64, @ptrFromInt(address)).*;
            if (raw_len < 0) return error.Invalid;
            const len: usize = @intCast(raw_len);
            const payload_words = (try checkedAdd(len, @sizeOf(i64) - 1)) / @sizeOf(i64);
            const total_bytes = try checkedMul(try checkedAdd(payload_words, 1), @sizeOf(i64));
            if (!runtime_owns_bytes(instance, address, total_bytes)) return error.Invalid;
            break :blk try checkedAdd(1 + @sizeOf(u32), len);
        },
        tag_float => blk: {
            if (runtime_local_kind(word) != null) return error.Unsupported;
            const address = @as(usize, @bitCast(word)) & ~tag_mask;
            if (!runtime_owns_bytes(instance, address, 2 * @sizeOf(i64))) return error.Invalid;
            break :blk switch (boxed_kind(word)) {
                boxed_float_kind => 1 + @sizeOf(i64),
                boxed_bigint_kind => size: {
                    const raw_len = boxed_words(word)[1];
                    if (raw_len <= 0) return error.Invalid;
                    const len: usize = @intCast(raw_len);
                    const payload_words = (try checkedAdd(len, @sizeOf(i64) - 1)) / @sizeOf(i64);
                    const total_bytes = try checkedMul(try checkedAdd(payload_words, 2), @sizeOf(i64));
                    if (!runtime_owns_bytes(instance, address, total_bytes)) return error.Invalid;
                    break :size try checkedAdd(1 + @sizeOf(u32), len);
                },
                else => error.Invalid,
            };
        },
        tag_fun => error.Unsupported,
        else => error.Invalid,
    };
}

fn writeU32(bytes: []u8, cursor: *usize, value: u32) void {
    for (0..4) |offset| bytes[cursor.* + offset] = @truncate(value >> @intCast(offset * 8));
    cursor.* += 4;
}

fn writeI64(bytes: []u8, cursor: *usize, value: i64) void {
    const bits: u64 = @bitCast(value);
    for (0..8) |offset| bytes[cursor.* + offset] = @truncate(bits >> @intCast(offset * 8));
    cursor.* += 8;
}

fn encodeTerm(instance: *Runtime, word: i64, root_scalar: bool, bytes: []u8, cursor: *usize) void {
    if (root_scalar) {
        bytes[cursor.*] = codec_scalar;
        cursor.* += 1;
        writeI64(bytes, cursor, word);
        return;
    }
    const tag = word_tag(word);
    bytes[cursor.*] = switch (tag) {
        tag_int => codec_int,
        tag_atom => codec_atom,
        tag_tuple => codec_tuple,
        tag_list => codec_cons,
        tag_map => codec_map,
        tag_binary => codec_binary,
        tag_float => if (is_bigint(word)) codec_bigint else codec_float,
        else => unreachable,
    };
    cursor.* += 1;
    switch (tag) {
        tag_int, tag_atom => writeI64(bytes, cursor, word),
        tag_float => if (is_bigint(word)) {
            const len = bigint_len(word);
            writeU32(bytes, cursor, @intCast(len));
            @memcpy(bytes[cursor.* .. cursor.* + len], bigint_bytes(word)[0..len]);
            cursor.* += len;
        } else {
            writeI64(bytes, cursor, @bitCast(float_bits(word)));
        },
        tag_tuple => {
            const len = tuple_len(word);
            writeU32(bytes, cursor, @intCast(len));
            for (tuple_elems(word)[0..len]) |child| encodeTerm(instance, child, false, bytes, cursor);
        },
        tag_list => {
            const cell = list_cell(word);
            encodeTerm(instance, cell[0], false, bytes, cursor);
            encodeTerm(instance, cell[1], false, bytes, cursor);
        },
        tag_map => {
            const len = map_len(word);
            writeU32(bytes, cursor, @intCast(len));
            for (map_entries(word)[0 .. len * 2]) |child| encodeTerm(instance, child, false, bytes, cursor);
        },
        tag_binary => {
            const len = binary_len(word);
            writeU32(bytes, cursor, @intCast(len));
            @memcpy(bytes[cursor.* .. cursor.* + len], binary_bytes(word)[0..len]);
            cursor.* += len;
        },
        else => unreachable,
    }
}

fn registerExported(instance: *Runtime, word: i64, root_scalar: bool) i64 {
    crossRuntimeTestReach(.export_traversal, instance);
    const term_size = encodedTermSize(instance, word, root_scalar, 0) catch |err| return switch (err) {
        error.Unsupported => -3,
        error.Invalid => -1,
        error.Limit => -4,
    };
    const byte_count = checkedAdd(exported_magic.len, term_size) catch return -4;
    const bytes = std.heap.page_allocator.alloc(u8, byte_count) catch return -2;
    @memcpy(bytes[0..exported_magic.len], &exported_magic);
    var cursor: usize = exported_magic.len;
    encodeTerm(instance, word, root_scalar, bytes, &cursor);

    exported_lock.lock();
    defer exported_lock.unlock();
    var offset: usize = 0;
    while (offset < exported_slot_cap) : (offset += 1) {
        const index = (exported_cursor + offset) % exported_slot_cap;
        const slot = &exported_slots[index];
        if (slot.bytes == null) {
            slot.bytes = bytes;
            slot.refs = 1;
            exported_cursor = (index + 1) % exported_slot_cap;
            return opaque_handle(index, slot.generation);
        }
    }
    std.heap.page_allocator.free(bytes);
    return 0;
}

const ExportLease = struct {
    runtime: *Runtime,
    word: i64,
    root_scalar: bool,
};

fn finish_export(instance: *Runtime) void {
    instance.lifecycle_lock.lock();
    defer instance.lifecycle_lock.unlock();
    std.debug.assert(instance.lifecycle_phase == .exporting);
    instance.lifecycle_phase = .idle;
}

fn begin_result_export(handle: i64, word: i64) error{ Invalid, Unsupported, Busy }!ExportLease {
    result_lock.lock();
    const initial = result_slot_locked(handle) orelse {
        result_lock.unlock();
        return error.Invalid;
    };
    const instance = initial.runtime.?;
    const runtime_handle = initial.runtime_handle;
    result_lock.unlock();

    runtime_lock.lock();
    const runtime_slot = runtime_slot_locked(runtime_handle) orelse {
        runtime_lock.unlock();
        return error.Invalid;
    };
    if (runtime_slot.runtime.? != instance) {
        runtime_lock.unlock();
        return error.Invalid;
    }
    instance.lifecycle_lock.lock();
    result_lock.lock();
    const slot = result_slot_locked(handle) orelse {
        result_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return error.Invalid;
    };
    if (slot.runtime.? != instance or slot.runtime_handle != runtime_handle) {
        result_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return error.Invalid;
    }
    if (instance.lifecycle_phase != .idle) {
        result_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return error.Busy;
    }
    if (runtime_local_kind(word) != null) {
        result_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return error.Unsupported;
    }
    const root_scalar = word == slot.word and !runtime_owns_word(instance, word);
    if (!root_scalar and result_term_kind_locked(slot, word) < 0) {
        result_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return error.Invalid;
    }
    instance.lifecycle_phase = .exporting;
    result_lock.unlock();
    instance.lifecycle_lock.unlock();
    runtime_lock.unlock();
    lifecycleTestReach(.result_export_committed, instance);
    return .{ .runtime = instance, .word = word, .root_scalar = root_scalar };
}

fn begin_term_export(handle: i64) error{ Invalid, Busy }!ExportLease {
    term_lock.lock();
    const initial = term_slot_locked(handle) orelse {
        term_lock.unlock();
        return error.Invalid;
    };
    const instance = initial.runtime.?;
    const runtime_handle = initial.runtime_handle;
    term_lock.unlock();

    runtime_lock.lock();
    const runtime_slot = runtime_slot_locked(runtime_handle) orelse {
        runtime_lock.unlock();
        return error.Invalid;
    };
    if (runtime_slot.runtime.? != instance) {
        runtime_lock.unlock();
        return error.Invalid;
    }
    instance.lifecycle_lock.lock();
    term_lock.lock();
    const slot = term_slot_locked(handle) orelse {
        term_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return error.Invalid;
    };
    if (slot.runtime.? != instance or slot.runtime_handle != runtime_handle) {
        term_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return error.Invalid;
    }
    if (instance.lifecycle_phase != .idle) {
        term_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return error.Busy;
    }
    const word = slot.word;
    const root_scalar = slot.root_scalar;
    instance.lifecycle_phase = .exporting;
    term_lock.unlock();
    instance.lifecycle_lock.unlock();
    runtime_lock.unlock();
    lifecycleTestReach(.term_export_committed, instance);
    return .{ .runtime = instance, .word = word, .root_scalar = root_scalar };
}

/// Copies a result-owned portable term into generation-checked host storage.
pub fn ex_term_export(handle: i64, word: i64) callconv(.c) i64 {
    const lease = begin_result_export(handle, word) catch |err| return switch (err) {
        error.Invalid => -1,
        error.Unsupported => -3,
        error.Busy => -5,
    };
    defer finish_export(lease.runtime);
    return registerExported(lease.runtime, lease.word, lease.root_scalar);
}

pub fn ex_term_exported_clone(handle: i64) callconv(.c) i64 {
    exported_lock.lock();
    defer exported_lock.unlock();
    const slot = exported_slot_locked(handle) orelse return -1;
    if (slot.refs == std.math.maxInt(u32)) return -4;
    slot.refs += 1;
    return handle;
}

pub fn ex_term_exported_destroy(handle: i64) callconv(.c) i64 {
    exported_lock.lock();
    defer exported_lock.unlock();
    const slot = exported_slot_locked(handle) orelse return -1;
    release_exported_locked(slot);
    return 0;
}

pub fn ex_term_exported_length(handle: i64) callconv(.c) i64 {
    exported_lock.lock();
    defer exported_lock.unlock();
    const slot = exported_slot_locked(handle) orelse return -1;
    return @intCast(slot.bytes.?.len);
}

pub fn ex_term_exported_get(handle: i64, index_word: i64) callconv(.c) i64 {
    if (index_word < 0) return -1;
    exported_lock.lock();
    defer exported_lock.unlock();
    const slot = exported_slot_locked(handle) orelse return -1;
    const index: usize = @intCast(index_word);
    if (index >= slot.bytes.?.len) return -1;
    return slot.bytes.?[index];
}

const Decoder = struct {
    bytes: []const u8,
    cursor: usize = exported_magic.len,

    fn readByte(self: *@This()) CodecError!u8 {
        if (self.cursor >= self.bytes.len) return error.Invalid;
        defer self.cursor += 1;
        return self.bytes[self.cursor];
    }

    fn readU32(self: *@This()) CodecError!u32 {
        if (self.bytes.len - self.cursor < 4) return error.Invalid;
        var value: u32 = 0;
        for (0..4) |offset| value |= @as(u32, self.bytes[self.cursor + offset]) << @intCast(offset * 8);
        self.cursor += 4;
        return value;
    }

    fn readI64(self: *@This()) CodecError!i64 {
        if (self.bytes.len - self.cursor < 8) return error.Invalid;
        var value: u64 = 0;
        for (0..8) |offset| value |= @as(u64, self.bytes[self.cursor + offset]) << @intCast(offset * 8);
        self.cursor += 8;
        return @bitCast(value);
    }

    fn skip(self: *@This(), count: usize) CodecError!void {
        if (count > self.bytes.len - self.cursor) return error.Invalid;
        self.cursor += count;
    }
};

fn decodedWords(decoder: *Decoder, depth: usize, root: bool) CodecError!usize {
    if (depth > exported_max_depth) return error.Limit;
    const kind = try decoder.readByte();
    return switch (kind) {
        codec_scalar => if (root) blk: {
            _ = try decoder.readI64();
            break :blk 0;
        } else error.Invalid,
        codec_int => blk: {
            const word = try decoder.readI64();
            if (word_tag(word) != tag_int) return error.Invalid;
            break :blk 0;
        },
        codec_atom => blk: {
            const word = try decoder.readI64();
            if (word_tag(word) != tag_atom or dynamic_atom_index(word) != null) return error.Invalid;
            break :blk 0;
        },
        codec_tuple => blk: {
            const len = try decoder.readU32();
            var words: usize = try checkedAdd(@as(usize, len), 1);
            for (0..len) |_| words = try checkedAdd(words, try decodedWords(decoder, depth + 1, false));
            break :blk words;
        },
        codec_cons => try checkedAdd(2, try checkedAdd(try decodedWords(decoder, depth + 1, false), try decodedWords(decoder, depth + 1, false))),
        codec_map => blk: {
            const len = try decoder.readU32();
            var words: usize = try checkedAdd(try checkedMul(@as(usize, len), 2), 1);
            for (0..len * 2) |_| words = try checkedAdd(words, try decodedWords(decoder, depth + 1, false));
            break :blk words;
        },
        codec_binary => blk: {
            const len = try decoder.readU32();
            try decoder.skip(len);
            break :blk try checkedAdd(1, (try checkedAdd(len, @sizeOf(i64) - 1)) / @sizeOf(i64));
        },
        codec_float => blk: {
            _ = try decoder.readI64();
            break :blk 2;
        },
        codec_bigint => blk: {
            const len = try decoder.readU32();
            if (len == 0) return error.Invalid;
            try decoder.skip(len);
            break :blk try checkedAdd(2, (try checkedAdd(len, @sizeOf(i64) - 1)) / @sizeOf(i64));
        },
        else => error.Invalid,
    };
}

fn decodeTerm(decoder: *Decoder, storage: [*]i64, next: *usize, root: bool, root_scalar: *bool) CodecError!i64 {
    const kind = try decoder.readByte();
    return switch (kind) {
        codec_scalar => if (root) blk: {
            root_scalar.* = true;
            break :blk try decoder.readI64();
        } else error.Invalid,
        codec_int => try decoder.readI64(),
        codec_atom => try decoder.readI64(),
        codec_tuple => blk: {
            const len = try decoder.readU32();
            const start = next.*;
            next.* += @as(usize, len) + 1;
            storage[start] = len;
            for (0..len) |index| storage[start + 1 + index] = try decodeTerm(decoder, storage, next, false, root_scalar);
            break :blk word_from_ptr(storage + start, tag_tuple);
        },
        codec_cons => blk: {
            const start = next.*;
            next.* += 2;
            storage[start] = try decodeTerm(decoder, storage, next, false, root_scalar);
            storage[start + 1] = try decodeTerm(decoder, storage, next, false, root_scalar);
            break :blk word_from_ptr(storage + start, tag_list);
        },
        codec_map => blk: {
            const len = try decoder.readU32();
            const start = next.*;
            next.* += @as(usize, len) * 2 + 1;
            storage[start] = len;
            for (0..len * 2) |index| storage[start + 1 + index] = try decodeTerm(decoder, storage, next, false, root_scalar);
            break :blk word_from_ptr(storage + start, tag_map);
        },
        codec_binary => blk: {
            const len = try decoder.readU32();
            const payload_words = (@as(usize, len) + @sizeOf(i64) - 1) / @sizeOf(i64);
            const start = next.*;
            next.* += payload_words + 1;
            storage[start] = len;
            const destination: [*]u8 = @ptrFromInt(@intFromPtr(storage + start) + @sizeOf(i64));
            @memcpy(destination[0..len], decoder.bytes[decoder.cursor .. decoder.cursor + len]);
            decoder.cursor += len;
            break :blk word_from_ptr(storage + start, tag_binary);
        },
        codec_float => blk: {
            const start = next.*;
            next.* += 2;
            storage[start] = boxed_float_kind;
            storage[start + 1] = try decoder.readI64();
            break :blk word_from_ptr(storage + start, tag_float);
        },
        codec_bigint => blk: {
            const len = try decoder.readU32();
            if (len == 0) return error.Invalid;
            const payload_words = (@as(usize, len) + @sizeOf(i64) - 1) / @sizeOf(i64);
            const start = next.*;
            next.* += payload_words + 2;
            storage[start] = boxed_bigint_kind;
            storage[start + 1] = len;
            const destination: [*]u8 = @ptrFromInt(@intFromPtr(storage + start) + 2 * @sizeOf(i64));
            @memcpy(destination[0..len], decoder.bytes[decoder.cursor .. decoder.cursor + len]);
            decoder.cursor += len;
            break :blk word_from_ptr(storage + start, tag_float);
        },
        else => error.Invalid,
    };
}

/// Imports an exported value into an explicitly entered target runtime.
pub fn ex_term_import(runtime_handle: i64, exported_handle: i64) callconv(.c) i64 {
    const bytes = retain_exported_bytes(exported_handle) catch |err| return switch (err) {
        error.Invalid => -1,
        error.Limit => -4,
    };
    defer release_exported_retain(exported_handle);
    if (bytes.len < exported_magic.len or !std.mem.eql(u8, bytes[0..exported_magic.len], &exported_magic)) return -4;
    var sizing = Decoder{ .bytes = bytes };
    const words = decodedWords(&sizing, 0, true) catch |err| return switch (err) {
        error.Unsupported => -3,
        error.Invalid => -4,
        error.Limit => -4,
    };
    if (sizing.cursor != bytes.len) return -4;

    if (active_runtime_handle != runtime_handle) return -5;
    const instance = active_runtime orelse return -5;
    instance.lifecycle_lock.lock();
    defer instance.lifecycle_lock.unlock();
    if (!is_execution_owner_locked(instance, runtime_handle) or
        instance.execution_participants != 1) return -5;
    lifecycleTestReach(.import_validated, instance);
    crossRuntimeTestReach(.import_decode, instance);

    const storage = if (words == 0) null else alloc_words(words) orelse return -2;
    var decoder = Decoder{ .bytes = bytes };
    var next: usize = 0;
    var root_scalar = false;
    const word = decodeTerm(&decoder, if (storage) |ptr| ptr else undefined, &next, true, &root_scalar) catch return -4;
    if (decoder.cursor != bytes.len or next != words) return -4;

    term_lock.lock();
    defer term_lock.unlock();
    var term_index: ?usize = null;
    var offset: usize = 0;
    while (offset < term_slot_cap) : (offset += 1) {
        const index = (term_cursor + offset) % term_slot_cap;
        if (term_slots[index].runtime == null) {
            term_index = index;
            break;
        }
    }
    const index = term_index orelse return 0;

    const slot = &term_slots[index];
    slot.runtime = instance;
    slot.runtime_handle = runtime_handle;
    slot.word = word;
    slot.root_scalar = root_scalar;
    _ = instance.outstanding_terms.fetchAdd(1, .acq_rel);
    term_cursor = (index + 1) % term_slot_cap;
    return opaque_handle(index, slot.generation);
}

pub fn ex_term_handle_export(handle: i64) callconv(.c) i64 {
    const lease = begin_term_export(handle) catch |err| return switch (err) {
        error.Invalid => -1,
        error.Busy => -5,
    };
    defer finish_export(lease.runtime);
    return registerExported(lease.runtime, lease.word, lease.root_scalar);
}

/// Returns the runtime word pinned by an imported term handle.
///
/// The caller must keep the handle alive until the compiled invocation that
/// consumes the word has returned. A stale handle returns -1.
pub fn ex_term_handle_root_word(handle: i64) callconv(.c) i64 {
    term_lock.lock();
    defer term_lock.unlock();
    const slot = term_slot_locked(handle) orelse return -1;
    return slot.word;
}

pub fn ex_term_handle_destroy(handle: i64) callconv(.c) i64 {
    term_lock.lock();
    const initial = term_slot_locked(handle) orelse {
        term_lock.unlock();
        return -1;
    };
    const instance = initial.runtime.?;
    const runtime_handle = initial.runtime_handle;
    term_lock.unlock();
    lifecycleTestReach(.term_destroy_snapshotted, instance);

    runtime_lock.lock();
    const runtime_slot = runtime_slot_locked(runtime_handle) orelse {
        runtime_lock.unlock();
        return -1;
    };
    if (runtime_slot.runtime.? != instance) {
        runtime_lock.unlock();
        return -1;
    }
    instance.lifecycle_lock.lock();
    term_lock.lock();
    const slot = term_slot_locked(handle) orelse {
        term_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return -1;
    };
    if (slot.runtime.? != instance or slot.runtime_handle != runtime_handle or
        instance.lifecycle_phase == .destroying)
    {
        term_lock.unlock();
        instance.lifecycle_lock.unlock();
        runtime_lock.unlock();
        return -1;
    }
    _ = instance.outstanding_terms.fetchSub(1, .acq_rel);
    slot.runtime = null;
    slot.runtime_handle = 0;
    slot.word = 0;
    slot.root_scalar = false;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    term_lock.unlock();
    instance.lifecycle_lock.unlock();
    runtime_lock.unlock();
    return 0;
}

fn init_processes(instance: *Runtime) void {
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
        init_processes(instance);
        instance.processes_initialized = true;
    }
    const proc = instance.processes[current_process];
    current_process_ptr = proc;
    return proc;
}

// Runtime-local immediates use tag 7 plus a high marker and subtype bit, so a
// host boundary can reject PIDs/references without confusing them with atoms
// or integers. PID data is (generation << index_bits) | (index + 1).
const index_bits: u6 = 24;
const index_mask: i64 = (1 << @intCast(index_bits)) - 1;

fn pid_of(index: usize, generation: u32) i64 {
    const data = (@as(u64, generation) << @intCast(index_bits)) |
        @as(u64, @intCast(index + 1));
    return runtime_local_word(runtime_local_pid, data);
}

fn pid_index(pid: i64) usize {
    if (!is_pid(pid)) return 0;
    const encoded = runtime_local_data(pid) & @as(u64, @intCast(index_mask));
    return if (encoded == 0) 0 else @intCast(encoded - 1);
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
pub fn ex_term_process_table_reset(cap: i64) callconv(.c) i64 {
    const instance = runtime();
    if (cap < 1 or cap > max_process_cap) return nil_word;
    if (worker_runtime != null) return -1;
    const explicit = active_runtime_handle != 0;
    if (explicit) {
        instance.lifecycle_lock.lock();
        defer instance.lifecycle_lock.unlock();
        if (!is_execution_owner_locked(instance, active_runtime_handle) or
            instance.execution_participants != 1 or
            instance.execution_initialized or
            instance.outstanding_results.load(.acquire) != 0 or
            instance.outstanding_terms.load(.acquire) != 0) return -1;
        const result = process_table_reset(instance, cap);
        instance.execution_initialized = true;
        return result;
    }
    return process_table_reset(instance, cap);
}

fn process_table_reset(instance: *Runtime, cap: i64) i64 {
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
    init_processes(instance);
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
threadlocal var unwind_kind: i64 = 0;
// The worker boundary is distinct from user try frames, so programs retain
// all 16 nested catch slots. An otherwise uncaught throw lands here and exits
// only the current actor instead of panicking the native runtime.
threadlocal var uncaught_boundary: ?*c.jmp_buf = null;

/// Size of the C `jmp_buf` so the compiled code can allocate it on its own
/// stack.
pub fn ex_term_jmp_buf_size() callconv(.c) i64 {
    return @sizeOf(c.jmp_buf);
}

/// Address of libc's `setjmp`, so the compiled code can call it indirectly
/// without the ORC linker resolving libc symbols.
pub fn ex_term_setjmp_addr() callconv(.c) i64 {
    return @bitCast(@intFromPtr(&c.setjmp));
}

/// Pushes a setjmp buffer for a try region.
pub fn ex_term_try_push(buf: *c.jmp_buf) callconv(.c) i64 {
    if (jmp_depth >= jmp_stack.len) return -1;
    jmp_stack[jmp_depth] = buf;
    jmp_depth += 1;
    return 0;
}

/// Pops the innermost try region's setjmp buffer.
pub fn ex_term_try_pop() callconv(.c) i64 {
    if (jmp_depth > 0) jmp_depth -= 1;
    return 0;
}

/// Throws a value to the innermost try region. A worker catches otherwise
/// uncaught values at the actor boundary; calls outside a worker still abort.
pub fn ex_term_throw(value: i64) callconv(.c) noreturn {
    throw_value = value;
    unwind_kind = 0;
    if (jmp_depth > 0) c.longjmp(jmp_stack[jmp_depth - 1], 1);
    if (uncaught_boundary) |boundary| c.longjmp(boundary, 1);
    @panic("uncaught throw outside an actor boundary");
}

/// Raises an exception to the innermost user catch frame or actor boundary.
/// `kind` remains separate from the user-controlled reason until a catch
/// value is requested.
pub fn ex_term_raise(reason: i64, kind: i64) callconv(.c) noreturn {
    throw_value = reason;
    unwind_kind = kind;
    if (jmp_depth > 0) c.longjmp(jmp_stack[jmp_depth - 1], 1);
    if (uncaught_boundary) |boundary| c.longjmp(boundary, 1);
    @panic("uncaught exception outside an actor boundary");
}

/// Returns `{kind, reason}` for the active unwind. Zero denotes `:throw`; a
/// positive boxed kind denotes the Erlang `:error` class. Keeping both shapes
/// tagged lets compiled catch patterns distinguish a thrown two-tuple from an
/// exception without changing the actor-boundary ABI.
pub fn ex_term_catch_value() callconv(.c) i64 {
    return tuple2(unwind_kind << @intCast(tag_shift), throw_value);
}

/// Invokes a host callback behind the runtime's uncaught throw/raise
/// boundary. `caught` is one when control returned through longjmp and zero
/// on the normal path; `kind` preserves typed raise metadata. The callback
/// must not retain the integer context beyond this synchronous call.
pub fn ex_term_protected_call(
    callback: ?*const fn (i64) callconv(.c) i64,
    context: i64,
    caught: *i64,
    kind: *i64,
) callconv(.c) i64 {
    caught.* = 0;
    kind.* = 0;
    const invoke = callback orelse {
        caught.* = -1;
        return nil_word;
    };

    var boundary: c.jmp_buf = undefined;
    const previous_boundary = uncaught_boundary;
    uncaught_boundary = &boundary;
    defer uncaught_boundary = previous_boundary;

    if (c.setjmp(&boundary) == 0) return invoke(context);

    caught.* = 1;
    kind.* = unwind_kind;
    return throw_value;
}

/// Returns the pid of the current execution context. The scalar slice runs a
/// single actor with pid 1 (the atom term with id 1).
pub fn ex_term_self() callconv(.c) i64 {
    return current_proc().pid;
}

/// Enqueues a message to the process's mailbox, routing by pid; returns the
/// message itself, or nil when the pid is invalid or the mailbox is full.
/// Message delivery does not bump the recipient's epoch in this slice: a
/// plain FIFO receive must observe the message on resume.
pub fn ex_term_send(pid: i64, msg: i64) callconv(.c) i64 {
    const sender = current_proc().pid;
    if (!is_pid(pid)) return nil_word;
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
pub fn ex_term_receive() callconv(.c) i64 {
    return current_proc().mailbox.pop() orelse nil_word;
}

/// The nil term word (atom id 0).
pub fn ex_term_nil() callconv(.c) i64 {
    return nil_word;
}

/// The current process's `receive ... after` timeout start; 0 when the wait
/// loop has not started timing yet.
pub fn ex_term_receive_start() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return proc.receive_start;
}

/// Sets the current process's `receive ... after` timeout start.
pub fn ex_term_receive_start_set(value: i64) callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.receive_start = value;
    return value;
}

/// Wall-clock milliseconds (UTC epoch) for `receive ... after` timeouts.
pub fn ex_term_monotonic_time() callconv(.c) i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * 1000 +
        @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

/// The BEAM native time unit (nanoseconds on 64-bit) for
/// `erlang.monotonic_time/0,1`.
pub fn ex_term_native_time() callconv(.c) i64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.tv_sec) * 1_000_000_000 + @as(i64, ts.tv_nsec);
}

/// Hands out a fresh logical-clock value for `erlang.unique_integer/0,1`;
/// `negative` selects the decreasing negative series.
pub fn ex_term_unique_integer(negative: i64) callconv(.c) i64 {
    const instance = runtime();
    instance.counter_lock.lock();
    defer instance.counter_lock.unlock();
    instance.unique_integer_counter += 1;
    return if (negative == 0) instance.unique_integer_counter else -instance.unique_integer_counter;
}

/// Number of messages in the current process's mailbox.
pub fn ex_term_mailbox_len() callconv(.c) i64 {
    return @intCast(current_proc().mailbox.count());
}

/// The message at `cursor` (0-based from the mailbox head) without removing
/// it; nil when out of range.
pub fn ex_term_mailbox_peek(cursor: i64) callconv(.c) i64 {
    const proc = current_proc();
    if (cursor < 0) return nil_word;
    return proc.mailbox.peek(@intCast(cursor)) orelse nil_word;
}

/// Removes the message at `cursor`, shifting later messages forward; returns
/// 1, or nil when out of range.
pub fn ex_term_mailbox_remove(cursor: i64) callconv(.c) i64 {
    const proc = current_proc();
    if (cursor < 0) return nil_word;
    return if (proc.mailbox.remove(@intCast(cursor))) 1 else nil_word;
}

/// Resets the mailbox. The compiled entry function calls this at the start of
/// the first slice; resumed slices skip it (guarded by the continuation check
/// in the lift) so messages that arrived while the process was suspended are
/// preserved.
pub fn ex_term_mailbox_clear() callconv(.c) i64 {
    current_proc().mailbox.clear();
    return nil_word;
}

/// Spawns a new process with its own mailbox, clock and entry closure;
/// returns its runtime-local pid word with generation + slot serial (#50 stage 2).
/// A completed process's slot is recycled first (stage 1) with a bumped
/// generation; otherwise the table grows dynamically, so spawn only fails on
/// allocation failure. `process_count` grows only to the concurrency peak.
pub fn ex_term_spawn(fun: i64) callconv(.c) i64 {
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
pub fn ex_term_cont_save(arg: i64, acc: i64, cursor: i64) callconv(.c) i64 {
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
pub fn ex_term_receive_cont_save(arg: i64, acc: i64, cursor: i64) callconv(.c) i64 {
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
pub fn ex_term_cont_pending() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active and proc.cont.epoch == proc.clock.epoch) 1 else 0;
}

/// 1 when the current process has any saved continuation (valid or stale).
/// The entry's mailbox reset is gated on this: a resume — even one whose
/// continuation was invalidated by a message arrival — must keep the messages
/// that arrived while the process was suspended.
pub fn ex_term_cont_active() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active) 1 else 0;
}

/// Clears the current process's saved continuation.
pub fn ex_term_cont_clear() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.cont.active = false;
    return 0;
}

/// Saved loop state (arg/acc/cursor) of the current process's continuation;
/// nil when none is pending.
pub fn ex_term_cont_load_arg() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active) proc.cont.arg else nil_word;
}

pub fn ex_term_cont_load_acc() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active) proc.cont.acc else nil_word;
}

pub fn ex_term_cont_load_cursor() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.cont.active) proc.cont.cursor else nil_word;
}

/// Advances to the next runnable process (round-robin from the current one)
/// and returns its pid. Stays on the current process when it is the only
/// runnable one.
pub fn ex_term_schedule_next() callconv(.c) i64 {
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
pub fn ex_term_process_claim_next(worker_id: i64) callconv(.c) i64 {
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
pub fn ex_term_process_release() callconv(.c) i64 {
    const proc = current_proc();
    const pid = proc.pid;
    proc.owner.store(0, .release);
    return pid;
}

/// Parks the current actor only when no message was appended beyond the
/// completed selective-receive scan cursor. Holding the mailbox lock across
/// the state transition prevents a lost wakeup with a concurrent send.
pub fn ex_term_process_wait(cursor: i64) callconv(.c) i64 {
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
    runtime_handle: i64,
    execution_epoch: u64,
    id: u32,
    dispatcher: *const fn (i64) callconv(.c) i64,

    fn run(self: @This()) void {
        const background = self.id > 1;
        if (background and !worker_join(self.instance, self.runtime_handle, self.execution_epoch)) return;
        if (!background) active_runtime = self.instance;
        defer {
            if (background) {
                _ = worker_leave();
            } else {
                arena_worker_id = 0;
                current_process = 0;
                current_process_ptr = null;
            }
        }
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
                    current_proc().exit_kind = unwind_kind;
                    jmp_depth = 0;
                    unwind_kind = 0;
                    uncaught_boundary = null;
                    _ = self.instance.active_actors.fetchSub(1, .acq_rel);
                    _ = ex_term_process_exit(reason);
                }
                continue;
            }

            if (processes_unfinished() == 0) break;
            std.Thread.yield() catch {};
        }
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
pub fn ex_term_worker_run(
    worker_count: i64,
    dispatcher: ?*const fn (i64) callconv(.c) i64,
) callconv(.c) i64 {
    if (worker_count <= 0 or worker_count > 64 or dispatcher == null) return -1;
    const instance = runtime();
    if (active_runtime_handle == 0) return -1;
    instance.lifecycle_lock.lock();
    if (!is_execution_owner_locked(instance, active_runtime_handle) or !instance.execution_initialized) {
        instance.lifecycle_lock.unlock();
        return -1;
    }
    const runtime_handle = active_runtime_handle;
    const execution_epoch = instance.execution_epoch;
    instance.lifecycle_lock.unlock();
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
                .runtime_handle = runtime_handle,
                .execution_epoch = execution_epoch,
                .id = @intCast(index + 2),
                .dispatcher = dispatcher.?,
            },
        }) catch break;
        started += 1;
    }

    Worker.run(.{
        .instance = instance,
        .runtime_handle = runtime_handle,
        .execution_epoch = execution_epoch,
        .id = 1,
        .dispatcher = dispatcher.?,
    });
    for (threads[0..started]) |thread| thread.join();
    if (started != background_count) return -1;

    return ex_term_process_result(pid_of(0, 1));
}

pub fn ex_term_worker_count() callconv(.c) i64 {
    return runtime().configured_workers.load(.acquire);
}

pub fn ex_term_worker_max_active() callconv(.c) i64 {
    return runtime().max_active_actors.load(.acquire);
}

pub fn ex_term_worker_migrations() callconv(.c) i64 {
    return @intCast(runtime().migrations.load(.acquire));
}

pub fn ex_term_process_thread_id(pid: i64) callconv(.c) i64 {
    const instance = runtime();
    if (!is_pid(pid)) return 0;
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const proc = resolve_pid(instance, pid) orelse return 0;
    return @intCast(proc.last_thread_id.load(.acquire));
}

/// Closure word of the current process's entry; 0 for the initial process
/// (the compiled `__batata_entry`).
pub fn ex_term_current_entry() callconv(.c) i64 {
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
pub fn ex_term_process_done(result: i64) callconv(.c) i64 {
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
pub fn ex_term_process_exit(reason: i64) callconv(.c) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const proc = current_proc();
    propagate_exit_locked(instance, proc, reason);
    return reason;
}

/// Sets the current process's trap-exit flag and returns its previous value.
pub fn ex_term_process_trap_exit(enabled: i64) callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    const previous: i64 = if (proc.trap_exit) 1 else 0;
    proc.trap_exit = enabled != 0;
    return previous;
}

/// Creates a symmetric link. Atom words for EXIT and normal are supplied by
/// compiled code because atom identifiers are program hashes, not runtime IDs.
pub fn ex_term_link(pid: i64, exit_tag: i64, normal_tag: i64) callconv(.c) i64 {
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
pub fn ex_term_unlink(pid: i64) callconv(.c) i64 {
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
pub fn ex_term_exit(pid: i64, reason: i64, exit_tag: i64, normal_tag: i64) callconv(.c) i64 {
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

/// Monitors a live process and returns a fresh runtime-local reference.
pub fn ex_term_monitor(
    pid: i64,
    down_tag: i64,
    process_tag: i64,
    normal_tag: i64,
) callconv(.c) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const target = resolve_pid(instance, pid) orelse return nil_word;
    target.state_lock.lock();
    defer target.state_lock.unlock();
    if (target.status == .done or target.status == .exited or target.monitor_count >= relation_cap)
        return nil_word;
    instance.monitor_ref_counter += 1;
    const reference = runtime_local_word(runtime_local_ref, @intCast(instance.monitor_ref_counter));
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
pub fn ex_term_demonitor(reference: i64) callconv(.c) i64 {
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
pub fn ex_term_processes_runnable() callconv(.c) i64 {
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
pub fn ex_term_process_result(pid: i64) callconv(.c) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    if (!is_pid(pid)) return nil_word;
    const proc = resolve_pid(instance, pid) orelse return nil_word;
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.status == .done) proc.result else nil_word;
}

/// Returns an abnormally exited process's reason; nil for a live, normally
/// completed, stale or unknown pid.
pub fn ex_term_process_exit_reason(pid: i64) callconv(.c) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    if (!is_pid(pid)) return nil_word;
    const proc = resolve_pid(instance, pid) orelse return nil_word;
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.status == .exited) proc.exit_reason else nil_word;
}

/// Exception discriminator for an abnormally exited process; zero denotes
/// an ordinary uncaught throw or a non-exception exit.
pub fn ex_term_process_exit_kind(pid: i64) callconv(.c) i64 {
    const instance = runtime();
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    if (!is_pid(pid)) return 0;
    const proc = resolve_pid(instance, pid) orelse return 0;
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.status == .exited) proc.exit_kind else 0;
}

/// Reads exception metadata through a retained host result handle.
pub fn ex_term_result_exception_kind(handle: i64) callconv(.c) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    const instance = slot.runtime.?;
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const proc = resolve_pid(instance, pid_of(0, 1)) orelse return 0;
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.status == .exited) proc.exit_kind else 0;
}

pub fn ex_term_result_exception_reason(handle: i64) callconv(.c) i64 {
    result_lock.lock();
    defer result_lock.unlock();
    const slot = result_slot_locked(handle) orelse return -1;
    const instance = slot.runtime.?;
    instance.scheduler_lock.lock();
    defer instance.scheduler_lock.unlock();
    const proc = resolve_pid(instance, pid_of(0, 1)) orelse return nil_word;
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return if (proc.status == .exited) proc.exit_reason else nil_word;
}

/// Sets the reduction budget and resets the used counter (epoch untouched).
pub fn ex_term_clock_init(budget: i64) callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.clock.budget = budget;
    proc.clock.used = 0;
    return budget;
}

/// Charges `cost` reductions; returns 1 when the budget is exhausted (the
/// caller should yield), else 0. Negative cost is clamped to zero.
pub fn ex_term_clock_tick(cost: i64) callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    if (cost > 0) proc.clock.used += cost;
    return if (proc.clock.used >= proc.clock.budget and proc.clock.budget > 0) 1 else 0;
}

/// Remaining reduction budget (clamped to >= 0); -1 when no budget is set.
pub fn ex_term_clock_budget_left() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    if (proc.clock.budget <= 0) return -1;
    const left = proc.clock.budget - proc.clock.used;
    return if (left < 0) 0 else left;
}

/// Current continuation-generation counter.
pub fn ex_term_clock_epoch() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    return proc.clock.epoch;
}

/// Bumps the epoch (message arrival / scheduler round); returns the new value.
pub fn ex_term_clock_bump_epoch() callconv(.c) i64 {
    const proc = current_proc();
    proc.state_lock.lock();
    defer proc.state_lock.unlock();
    proc.clock.epoch += 1;
    const result = proc.clock.epoch;
    return result;
}

/// Number of preemptive yields so far (slice boundaries in the loop driver).
pub fn ex_term_yield_count() callconv(.c) i64 {
    const instance = runtime();
    instance.counter_lock.lock();
    defer instance.counter_lock.unlock();
    return instance.yield_count;
}

/// Records one yield at a slice boundary and bumps the yield counter.
pub fn ex_term_yield_mark() callconv(.c) i64 {
    const instance = runtime();
    instance.counter_lock.lock();
    defer instance.counter_lock.unlock();
    instance.yield_count += 1;
    return instance.yield_count;
}

/// Untags an integer term word to its scalar value; 0 for non-integers (the
/// caller is expected to have checked `is_integer` first).
pub fn ex_term_to_int(word: i64) callconv(.c) i64 {
    if (word_tag(word) != tag_int) return 0;
    return word_payload(word);
}

/// Constructs a first-class function value: a closure word holding the index
/// of the extracted `__fn_*` and up to four captured env words.
pub fn ex_term_make_fun(fn_idx: i64, env_len: i64, e0: i64, e1: i64, e2: i64, e3: i64) callconv(.c) i64 {
    if (env_len < 0 or env_len > 4) return nil_word;
    const words = alloc_words(6) orelse return nil_word;
    words[0] = fn_idx;
    words[1] = env_len;
    const env = [4]i64{ e0, e1, e2, e3 };
    for (0..@as(usize, @intCast(env_len))) |i| words[2 + i] = env[i];
    return word_from_ptr(words, tag_fun);
}

/// Constructs an arity-carrying closure while leaving the legacy closure
/// layout readable for callers that still use `ex.term.make_fun`.
pub fn ex_term_make_fun_with_arity(fn_idx: i64, arity: i64, env_len: i64, e0: i64, e1: i64, e2: i64, e3: i64) callconv(.c) i64 {
    if (arity < 0 or arity > 4 or env_len < 0 or env_len > 4) return nil_word;
    const words = alloc_words(7) orelse return nil_word;
    words[0] = fn_idx;
    words[1] = @bitCast(fun_arity_marker | @as(u64, @intCast(env_len)));
    words[2] = arity;
    const env = [4]i64{ e0, e1, e2, e3 };
    for (0..@as(usize, @intCast(env_len))) |i| words[3 + i] = env[i];
    return word_from_ptr(words, tag_fun);
}

/// Constructs a closure carrying its call arity and result representation.
/// result_mode 0 is a raw scalar and 1 is a tagged term word.
pub fn ex_term_make_fun_with_signature(fn_idx: i64, arity: i64, result_mode: i64, env_len: i64, e0: i64, e1: i64, e2: i64, e3: i64) callconv(.c) i64 {
    if (arity < 0 or arity > 4 or result_mode < 0 or result_mode > 1 or env_len < 0 or env_len > 4) return nil_word;
    const words = alloc_words(8) orelse return nil_word;
    words[0] = fn_idx;
    words[1] = @bitCast(fun_arity_marker | fun_signature_marker | @as(u64, @intCast(env_len)));
    words[2] = arity;
    words[3] = result_mode;
    const env = [4]i64{ e0, e1, e2, e3 };
    for (0..@as(usize, @intCast(env_len))) |i| words[4 + i] = env[i];
    return word_from_ptr(words, tag_fun);
}

/// Returns the function index of a closure word; 0 for non-functions.
pub fn ex_term_fun_idx(fun: i64) callconv(.c) i64 {
    if (word_tag(fun) != tag_fun) return 0;
    return fun_words(fun)[0];
}

/// Returns a closure's declared arity; -1 for non-functions and legacy
/// closures whose layout did not carry arity.
pub fn ex_term_fun_arity(fun: i64) callconv(.c) i64 {
    if (word_tag(fun) != tag_fun or !fun_has_arity(fun)) return -1;
    return fun_words(fun)[2];
}

/// Returns 0 for scalar-result closures, 1 for term-result closures, and -1
/// for values or legacy closures without result metadata.
pub fn ex_term_fun_result_mode(fun: i64) callconv(.c) i64 {
    if (word_tag(fun) != tag_fun or !fun_has_signature(fun)) return -1;
    return fun_words(fun)[3];
}

/// Returns the `index`-th captured env word of a closure; nil for
/// non-functions or out-of-range indices.
pub fn ex_term_fun_env(fun: i64, index: i64) callconv(.c) i64 {
    if (word_tag(fun) != tag_fun) return nil_word;
    const words = fun_words(fun);
    const env_len = fun_env_len(fun);
    if (index < 0 or index >= @as(i64, @intCast(env_len))) return nil_word;
    return words[fun_env_offset(fun) + @as(usize, @intCast(index))];
}

/// Conses a head word onto a list tail, returning a proper list word.
pub fn ex_term_list_cons(head: i64, tail: i64) callconv(.c) i64 {
    const cell = alloc_words(2) orelse return nil_word;
    cell[0] = head;
    cell[1] = tail;
    return word_from_ptr(cell, tag_list);
}

fn flatten_list_reversed(list: i64, reversed: *i64, depth: usize) bool {
    if (depth > exported_max_depth) return false;

    var current = list;
    while (word_tag(current) == tag_list) {
        const cell = list_cell(current);
        const head = cell[0];
        if (is_list_word(head)) {
            if (!flatten_list_reversed(head, reversed, depth + 1)) return false;
        } else {
            const next = ex_term_list_cons(head, reversed.*);
            if (word_tag(next) != tag_list) return false;
            reversed.* = next;
        }
        current = cell[1];
    }
    return current == nil_word;
}

/// Recursively flattens a proper list while preserving non-list terms as
/// leaves. The integer zero word is returned as an invalid-list sentinel.
pub fn ex_term_list_flatten(list: i64) callconv(.c) i64 {
    if (!is_list_word(list)) return 0;

    var reversed = nil_word;
    if (!flatten_list_reversed(list, &reversed, 0)) return 0;

    var result = nil_word;
    var current = reversed;
    while (word_tag(current) == tag_list) {
        const cell = list_cell(current);
        const next = ex_term_list_cons(cell[0], result);
        if (word_tag(next) != tag_list) return 0;
        result = next;
        current = cell[1];
    }
    return result;
}

/// Converts a proper list word into a tuple word.
pub fn ex_term_tuple_from_list(list: i64) callconv(.c) i64 {
    const len = list_len(list);
    const tuple = alloc_words(len + 1) orelse return nil_word;
    tuple[0] = @intCast(len);
    copy_list_into(tuple[1 .. len + 1], list);
    return word_from_ptr(tuple, tag_tuple);
}

/// Reads the element at `index` from a tuple word; nil for out-of-range or
/// non-tuples (the caller is expected to have checked `is_tuple` first).
pub fn ex_term_tuple_get(tuple: i64, index: i64) callconv(.c) i64 {
    if (word_tag(tuple) != tag_tuple) return nil_word;
    const len = tuple_len(tuple);
    if (index < 0 or index >= @as(i64, @intCast(len))) return nil_word;
    return tuple_elems(tuple)[@intCast(index)];
}

/// Returns the arity of a tuple word; 0 for non-tuples.
pub fn ex_term_tuple_length(tuple: i64) callconv(.c) i64 {
    if (word_tag(tuple) != tag_tuple) return 0;
    return @intCast(tuple_len(tuple));
}

/// Returns the pair count of a map word; 0 for non-maps.
pub fn ex_term_map_length(map: i64) callconv(.c) i64 {
    if (word_tag(map) != tag_map) return 0;
    return @intCast(map_len(map));
}

/// Returns `{found, value}` for a map key. `found` is a tagged integer term,
/// so a stored nil value remains distinguishable from a missing key.
pub fn ex_term_map_fetch(map: i64, key: i64) callconv(.c) i64 {
    if (word_tag(map) != tag_map) return tuple2(0, nil_word);
    const len = map_len(map);
    const entries = map_entries(map);
    for (0..len) |i| {
        if (term_eq(entries[i * 2], key)) return tuple2(1 << tag_shift, entries[i * 2 + 1]);
    }
    return tuple2(0, nil_word);
}

/// Returns the element count of an enumerable term: list length, tuple
/// arity, map pair count, or binary byte length; 0 for non-enumerables.
pub fn ex_term_enumerable_count(word: i64) callconv(.c) i64 {
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
pub fn ex_term_enumerable_to_list(enumerable: i64) callconv(.c) i64 {
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
                    @as(i64, binary_bytes(enumerable)[i]) << @intCast(tag_shift),
                    result,
                );
            }
            return result;
        },
        else => return nil_word,
    }
}

/// Materializes an enumerable and inserts `separator` between adjacent
/// elements. Empty and single-element inputs do not allocate separators;
/// nil is returned for unsupported enumerable tags.
pub fn ex_term_enumerable_intersperse(enumerable: i64, separator: i64) callconv(.c) i64 {
    if (!is_list_word(enumerable) and
        word_tag(enumerable) != tag_tuple and
        word_tag(enumerable) != tag_map and
        word_tag(enumerable) != tag_binary) return nil_word;

    var current = ex_term_enumerable_to_list(enumerable);
    var reversed = nil_word;
    var first = true;
    while (word_tag(current) == tag_list) {
        const cell = list_cell(current);
        if (!first) reversed = ex_term_list_cons(separator, reversed);
        reversed = ex_term_list_cons(cell[0], reversed);
        first = false;
        current = cell[1];
    }

    var result = nil_word;
    current = reversed;
    while (word_tag(current) == tag_list) {
        const cell = list_cell(current);
        result = ex_term_list_cons(cell[0], result);
        current = cell[1];
    }
    return result;
}

/// Materializes an inclusive integer range as a list.
pub fn ex_term_enumerable_to_list_range(start: i64, stop: i64) callconv(.c) i64 {
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
pub fn ex_term_enumerable_map_fun(
    enumerable: i64,
    mapper: ?*const fn (i64) callconv(.c) i64,
) callconv(.c) i64 {
    const count = ex_term_enumerable_count(enumerable);
    var result = nil_word;
    var i: i64 = count;
    while (i > 0) {
        i -= 1;
        const item =
            switch (word_tag(enumerable)) {
                tag_list => ex_term_list_get(enumerable, i),
                tag_tuple => ex_term_tuple_get(enumerable, i),
                tag_binary => (@as(i64, binary_bytes(enumerable)[@intCast(i)]) << @intCast(tag_shift)),
                else => nil_word,
            };
        const mapped = mapper.?(word_value(item));
        result = ex_term_list_cons(mapped << @intCast(tag_shift), result);
    }
    return result;
}

/// Maps an enumerable with a term-aware compiled mapper. Unlike the scalar
/// mapper ABI above, both the item passed to the callback and its result stay
/// tagged term words, allowing tuple/list/map pattern matching and term
/// construction in the mapper body.
pub fn ex_term_enumerable_map_term_fun(
    enumerable: i64,
    mapper: ?*const fn (i64) callconv(.c) i64,
) callconv(.c) i64 {
    const count = ex_term_enumerable_count(enumerable);
    var result = nil_word;
    var i: i64 = count;
    while (i > 0) {
        i -= 1;
        const item =
            switch (word_tag(enumerable)) {
                tag_list => ex_term_list_get(enumerable, i),
                tag_tuple => ex_term_tuple_get(enumerable, i),
                tag_binary => (@as(i64, binary_bytes(enumerable)[@intCast(i)]) << @intCast(tag_shift)),
                else => nil_word,
            };
        result = ex_term_list_cons(mapper.?(item), result);
    }
    return result;
}

/// Maps an enumerable with a captured term callback using the compiler's
/// fixed closure ABI: four environment words followed by four argument
/// words. The tagged item occupies the first argument slot.
pub fn ex_term_enumerable_map_term_fun_c(
    enumerable: i64,
    mapper: ?*const fn (i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64,
    env0: i64,
    env1: i64,
    env2: i64,
    env3: i64,
) callconv(.c) i64 {
    const count = ex_term_enumerable_count(enumerable);
    var result = nil_word;
    var i: i64 = count;
    while (i > 0) {
        i -= 1;
        const item =
            switch (word_tag(enumerable)) {
                tag_list => ex_term_list_get(enumerable, i),
                tag_tuple => ex_term_tuple_get(enumerable, i),
                tag_binary => (@as(i64, binary_bytes(enumerable)[@intCast(i)]) << @intCast(tag_shift)),
                else => nil_word,
            };
        result = ex_term_list_cons(mapper.?(env0, env1, env2, env3, item, 0, 0, 0), result);
    }
    return result;
}

/// Flat-maps an enumerable with a tagged term callback. Each callback result
/// is materialized through the enumerable protocol subset and concatenated
/// in input order.
pub fn ex_term_enumerable_flat_map_term_fun(
    enumerable: i64,
    mapper: ?*const fn (i64) callconv(.c) i64,
) callconv(.c) i64 {
    const count = ex_term_enumerable_count(enumerable);
    var result = nil_word;
    var i: i64 = count;
    while (i > 0) {
        i -= 1;
        const item =
            switch (word_tag(enumerable)) {
                tag_list => ex_term_list_get(enumerable, i),
                tag_tuple => ex_term_tuple_get(enumerable, i),
                tag_binary => (@as(i64, binary_bytes(enumerable)[@intCast(i)]) << @intCast(tag_shift)),
                else => nil_word,
            };

        var mapped = ex_term_enumerable_to_list(mapper.?(item));
        var reversed = nil_word;
        while (word_tag(mapped) == tag_list) {
            const cell = list_cell(mapped);
            reversed = ex_term_list_cons(cell[0], reversed);
            mapped = cell[1];
        }
        while (word_tag(reversed) == tag_list) {
            const cell = list_cell(reversed);
            result = ex_term_list_cons(cell[0], result);
            reversed = cell[1];
        }
    }
    return result;
}

/// Filters a list by a compiled predicate `(item: i64) -> i64` (nonzero
/// keeps), producing a list in order.
pub fn ex_term_stream_filter(
    list: i64,
    predicate: ?*const fn (i64) callconv(.c) i64,
) callconv(.c) i64 {
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
pub fn ex_term_stream_take(list: i64, n: i64) callconv(.c) i64 {
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
pub fn ex_term_stream_drop(list: i64, n: i64) callconv(.c) i64 {
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
pub fn ex_term_enumerable_reduce(enumerable: i64, acc: i64, continuation: i64) callconv(.c) i64 {
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
pub fn ex_term_enumerable_reduce_c(
    enumerable: i64,
    acc: i64,
    continuation: i64,
    capture: i64,
) callconv(.c) i64 {
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
pub fn ex_term_enumerable_reduce_range(
    start: i64,
    stop: i64,
    acc: i64,
    continuation: i64,
) callconv(.c) i64 {
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
pub fn ex_term_enumerable_reduce_fun(
    enumerable: i64,
    acc: i64,
    reducer: ?*const fn (i64, i64) callconv(.c) i64,
) callconv(.c) i64 {
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
pub fn ex_term_register_callback(
    fn_id: i64,
    callback: ?*const fn (i64) callconv(.c) i64,
) callconv(.c) i64 {
    if (fn_id < 0 or fn_id >= beam_callback_cap) return -1;
    const instance = runtime();
    instance.callback_lock.lock();
    defer instance.callback_lock.unlock();
    instance.callbacks[@intCast(fn_id)] = callback;
    return 0;
}

/// Calls a registered native callback entry with an argument word; -1 when
/// the id is out of range or not registered.
pub fn ex_term_call_callback(fn_id: i64, arg: i64) callconv(.c) i64 {
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
pub fn ex_term_mapset_from_list(list: i64) callconv(.c) i64 {
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
pub fn ex_term_mapset_member(set: i64, member: i64) callconv(.c) i64 {
    return if (word_tag(set) == tag_list and list_contains(set, member)) 1 else 0;
}

/// Adds a member to a set (deduplicated); the original set is returned when
/// the member is already present.
pub fn ex_term_mapset_put(set: i64, member: i64) callconv(.c) i64 {
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
pub fn ex_term_file_read(path_word: i64) callconv(.c) i64 {
    return read_file_binary(path_word) orelse nil_word;
}

/// Reads a file and splits it into a list of line binaries (without trailing
/// newlines); nil on read failure.
pub fn ex_term_file_read_lines(path_word: i64) callconv(.c) i64 {
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
pub fn ex_term_list_head(list: i64) callconv(.c) i64 {
    if (!is_list_cell_word(list)) return nil_word;
    return list_cell(list)[0];
}

/// Returns the tail of a list word; nil for non-lists or the empty list.
pub fn ex_term_list_tail(list: i64) callconv(.c) i64 {
    if (!is_list_cell_word(list)) return nil_word;
    return list_cell(list)[1];
}

/// Returns the element at index of a list word; nil when out of range or
/// not a list.
pub fn ex_term_list_get(list: i64, index: i64) callconv(.c) i64 {
    if (!is_list_cell_word(list)) return nil_word;
    var cell = list_cell(list);
    var i: i64 = 0;
    while (i < index) : (i += 1) {
        const tail = cell[1];
        if (!is_list_cell_word(tail)) return nil_word;
        cell = list_cell(tail);
    }
    return cell[0];
}

/// Returns the length of a list word (0 for nil, the empty list).
pub fn ex_term_list_length(list: i64) callconv(.c) i64 {
    return @intCast(list_len(list));
}

/// Deep equality: exact for immediate terms, structural for containers
/// (tuples, lists, maps, binaries). Terms are immutable on the bump heap, so
/// no cycle handling is needed.
pub fn ex_term_eq(left: i64, right: i64) callconv(.c) i64 {
    return if (term_eq(left, right)) 1 else 0;
}

/// BEAM-style loose equality: integers and floats compare by numeric value,
/// including when nested in tuples, lists, or maps. Other terms keep the
/// runtime's structural equality semantics.
pub fn ex_term_eq_loose(left: i64, right: i64) callconv(.c) i64 {
    return if (term_eq_loose(left, right)) 1 else 0;
}

fn numeric_eq(int_word: i64, float_word: i64) bool {
    const value: f64 = @bitCast(float_bits(float_word));
    if (!std.math.isFinite(value) or @trunc(value) != value) return false;

    const min_i64: f64 = @floatFromInt(std.math.minInt(i64));
    const max_i64: f64 = @floatFromInt(std.math.maxInt(i64));
    if (value < min_i64 or value >= max_i64) return false;

    return word_payload(int_word) == @as(i64, @intFromFloat(value));
}

fn term_eq_loose(left: i64, right: i64) bool {
    if (left == right) return true;

    const ltag = word_tag(left);
    const rtag = word_tag(right);
    const left_float = ltag == tag_float and is_boxed_float(left);
    const right_float = rtag == tag_float and is_boxed_float(right);

    if (ltag == tag_int and right_float) return numeric_eq(left, right);
    if (rtag == tag_int and left_float) return numeric_eq(right, left);
    if (ltag != rtag) return false;

    if (ltag == tag_runtime_local and
        (runtime_local_kind(left) != null or runtime_local_kind(right) != null)) return false;

    switch (ltag) {
        tag_tuple => {
            if (tuple_len(left) != tuple_len(right)) return false;
            const n = tuple_len(left);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (!term_eq_loose(tuple_elems(left)[i], tuple_elems(right)[i])) return false;
            }
            return true;
        },
        tag_list => {
            var a = left;
            var b = right;
            while (word_tag(a) == tag_list and word_tag(b) == tag_list) {
                if (!term_eq_loose(list_cell(a)[0], list_cell(b)[0])) return false;
                a = list_cell(a)[1];
                b = list_cell(b)[1];
            }
            return term_eq_loose(a, b);
        },
        tag_map => {
            if (map_len(left) != map_len(right)) return false;
            const n = map_len(left);
            var i: usize = 0;
            while (i < 2 * n) : (i += 1) {
                if (!term_eq_loose(map_entries(left)[i], map_entries(right)[i])) return false;
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
        tag_float => {
            if (is_bigint(left) or is_bigint(right)) {
                return is_bigint(left) and is_bigint(right) and bigint_eq(left, right);
            }
            const a: f64 = @bitCast(float_bits(left));
            const b: f64 = @bitCast(float_bits(right));
            return a == b;
        },
        else => return false,
    }
}

fn term_eq(left: i64, right: i64) bool {
    if (left == right) return true;
    const ltag = word_tag(left);
    if (ltag != word_tag(right)) return false;
    if (ltag == tag_runtime_local and
        (runtime_local_kind(left) != null or runtime_local_kind(right) != null)) return false;

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
        tag_float => {
            if (is_bigint(left) or is_bigint(right)) {
                return is_bigint(left) and is_bigint(right) and bigint_eq(left, right);
            }
            return float_bits(left) == float_bits(right);
        },
        else => return false,
    }
}

/// Boxes an IEEE-754 binary64 bit pattern as a first-class dynamic term.
pub fn ex_term_float_lit(bits: i64) callconv(.c) i64 {
    const payload = alloc_words(2) orelse return nil_word;
    payload[0] = boxed_float_kind;
    payload[1] = bits;
    return word_from_ptr(payload, tag_float);
}

fn canonical_decimal_integer(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const digits = if (bytes[0] == '-') bytes[1..] else bytes;
    if (digits.len == 0 or (digits.len > 1 and digits[0] == '0')) return false;
    for (digits) |byte| {
        if (byte < '0' or byte > '9') return false;
    }
    return true;
}

/// Constructs an integer term from a canonical base-10 binary. Values in the
/// immediate signed-61 domain keep the zero-allocation representation; larger
/// values retain their canonical bytes in an arena-owned boxed integer.
pub fn ex_term_bigint_lit(binary: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary) return nil_word;
    const bytes = binary_bytes(binary)[0..binary_len(binary)];
    if (!canonical_decimal_integer(bytes)) return nil_word;

    const immediate_min = -(@as(i64, 1) << 60);
    const immediate_max = (@as(i64, 1) << 60) - 1;
    if (std.fmt.parseInt(i64, bytes, 10)) |value| {
        if (value >= immediate_min and value <= immediate_max) {
            return value * (@as(i64, 1) << @intCast(tag_shift));
        }
    } else |_| {}

    const payload_words = (bytes.len + @sizeOf(i64) - 1) / @sizeOf(i64);
    const payload = alloc_words(payload_words + 2) orelse return nil_word;
    payload[0] = boxed_bigint_kind;
    payload[1] = @intCast(bytes.len);
    @memset(payload[2 .. payload_words + 2], 0);
    const destination: [*]u8 = @ptrFromInt(@intFromPtr(payload) + 2 * @sizeOf(i64));
    @memcpy(destination[0..bytes.len], bytes);
    return word_from_ptr(payload, tag_float);
}

pub fn ex_term_is_float(word: i64) callconv(.c) i64 {
    return if (is_boxed_float(word)) 1 else 0;
}

/// Returns the IEEE-754 binary64 payload for an arena-owned float term.
/// Zero is returned for non-floats and foreign/stale arena pointers; callers
/// distinguish a valid `0.0` by checking `ex_term_is_float` first.
pub fn ex_term_float_bits(word: i64) callconv(.c) i64 {
    if (ex_term_is_float(word) == 0) return 0;
    const instance = runtime();
    if (!runtime_owns_word(instance, word)) return 0;
    return @bitCast(float_bits(word));
}

/// Parses a BEAM-compatible float binary into a boxed binary64 term.
/// Invalid syntax and non-finite results return nil; callers own error shape.
pub fn ex_term_string_to_float(binary: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary) return nil_word;
    const bytes = binary_bytes(binary)[0..binary_len(binary)];
    if (!valid_float_syntax(bytes)) return nil_word;
    const value = std.fmt.parseFloat(f64, bytes) catch return nil_word;
    if (!std.math.isFinite(value)) return nil_word;
    return ex_term_float_lit(@bitCast(@as(u64, @bitCast(value))));
}

fn ensure_float_marker(src: []const u8, out: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src, '.')) |_| return src;

    if (std.mem.indexOfScalar(u8, src, 'e')) |index| {
        @memcpy(out[0..index], src[0..index]);
        @memcpy(out[index..][0..2], ".0");
        @memcpy(out[index + 2 ..][0 .. src.len - index], src[index..]);
        return out[0 .. src.len + 2];
    }

    @memcpy(out[0..src.len], src);
    @memcpy(out[src.len..][0..2], ".0");
    return out[0 .. src.len + 2];
}

/// Formats a boxed finite binary64 term with Erlang's `[:short]` contract.
/// Zig's Ryu formatter supplies the shortest round-trip mantissa. Erlang uses
/// scientific notation at and beyond the binary64 exact-integer boundary;
/// below that boundary it uses the shorter valid spelling (decimal on equal
/// length).
pub fn ex_term_float_to_binary_short(word: i64) callconv(.c) i64 {
    if (!is_boxed_float(word)) return nil_word;
    const value: f64 = @bitCast(float_bits(word));
    if (!std.math.isFinite(value)) return nil_word;

    var decimal_buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
    var scientific_buf: [std.fmt.float.bufferSize(.scientific, f64)]u8 = undefined;
    var decimal_marked_buf: [decimal_buf.len + 2]u8 = undefined;
    var scientific_marked_buf: [scientific_buf.len + 2]u8 = undefined;

    const decimal = std.fmt.float.render(&decimal_buf, value, .{ .mode = .decimal }) catch return nil_word;
    const scientific = std.fmt.float.render(&scientific_buf, value, .{ .mode = .scientific }) catch return nil_word;
    const decimal_marked = ensure_float_marker(decimal, &decimal_marked_buf);
    const scientific_marked = ensure_float_marker(scientific, &scientific_marked_buf);
    const rendered = if (@abs(value) >= 9_007_199_254_740_992.0 or scientific_marked.len < decimal_marked.len)
        scientific_marked
    else
        decimal_marked;

    const words = alloc_binary(rendered.len) orelse return nil_word;
    const result = word_from_ptr(words, tag_binary);
    @memcpy(binary_bytes(result)[0..rendered.len], rendered);
    return result;
}

fn valid_float_syntax(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var cursor: usize = 0;
    if (bytes[cursor] == '+' or bytes[cursor] == '-') cursor += 1;
    const integer_start = cursor;
    while (cursor < bytes.len and std.ascii.isDigit(bytes[cursor])) cursor += 1;
    if (cursor == integer_start or cursor >= bytes.len or bytes[cursor] != '.') return false;
    cursor += 1;
    const fraction_start = cursor;
    while (cursor < bytes.len and std.ascii.isDigit(bytes[cursor])) cursor += 1;
    if (cursor == fraction_start) return false;
    if (cursor == bytes.len) return true;
    if (bytes[cursor] != 'e' and bytes[cursor] != 'E') return false;
    cursor += 1;
    if (cursor < bytes.len and (bytes[cursor] == '+' or bytes[cursor] == '-')) cursor += 1;
    const exponent_start = cursor;
    while (cursor < bytes.len and std.ascii.isDigit(bytes[cursor])) cursor += 1;
    return cursor > exponent_start and cursor == bytes.len;
}

/// Returns the byte length of a binary word; 0 for non-binaries.
pub fn ex_term_binary_length(binary: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary) return 0;
    return @intCast(binary_len(binary));
}

/// Copies host-owned bytes into a runtime-owned binary. The host buffer is
/// never retained. Returns nil for invalid input or allocation failure.
pub fn ex_term_binary_from_bytes(bytes: ?[*]const u8, length: i64) callconv(.c) i64 {
    if (length < 0) return nil_word;
    const len: usize = @intCast(length);
    if (len != 0 and bytes == null) return nil_word;
    const binary = alloc_binary(len) orelse return nil_word;
    const result = word_from_ptr(binary, tag_binary);
    if (len != 0) @memcpy(binary_bytes(result)[0..len], bytes.?[0..len]);
    return result;
}

/// Copies a runtime binary into host-owned storage without exposing the
/// runtime allocation. Returns its length or -1 on failure.
pub fn ex_term_binary_copy(binary: i64, destination: ?[*]u8, capacity: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary or capacity < 0) return -1;
    const len = binary_len(binary);
    if (len > @as(usize, @intCast(capacity)) or (len != 0 and destination == null)) return -1;
    if (len != 0) @memcpy(destination.?[0..len], binary_bytes(binary)[0..len]);
    return @intCast(len);
}

/// Reads the byte at `index` as a tagged int term; nil for out-of-range or
/// non-binaries (the caller is expected to have checked `is_binary` first).
pub fn ex_term_binary_get(binary: i64, index: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary) return nil_word;
    const len = binary_len(binary);
    if (index < 0 or index >= @as(i64, @intCast(len))) return nil_word;
    const byte: i64 = binary_bytes(binary)[@intCast(index)];
    return (byte & 0xFF) << @intCast(tag_shift);
}

/// Materializes a new binary word from bytes [start..len); nil for
/// non-binaries or an out-of-range start.
pub fn ex_term_binary_slice(binary: i64, start: i64) callconv(.c) i64 {
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

/// Materializes a binary part. Start and length are tagged integer terms;
/// negative lengths select bytes immediately preceding start, matching the
/// BEAM binary_part/3 contract. Invalid terms and ranges return nil.
pub fn ex_term_binary_part(binary: i64, start_word: i64, length_word: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary or !is_int(start_word) or !is_int(length_word)) return nil_word;
    const len: i64 = @intCast(binary_len(binary));
    const start = word_payload(start_word);
    const length = word_payload(length_word);
    if (start < 0 or start > len) return nil_word;

    const normalized_start, const normalized_length = if (length >= 0) blk: {
        if (length > len - start) return nil_word;
        break :blk .{ start, length };
    } else blk: {
        if (length < -start) return nil_word;
        break :blk .{ start + length, -length };
    };

    const start_index: usize = @intCast(normalized_start);
    const part_len: usize = @intCast(normalized_length);

    const part = alloc_binary(part_len) orelse return nil_word;
    const part_word = word_from_ptr(part, tag_binary);
    if (part_len != 0) {
        @memcpy(binary_bytes(part_word)[0..part_len], binary_bytes(binary)[start_index .. start_index + part_len]);
    }
    return part_word;
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
pub fn ex_term_binary_utf8_get(binary: i64, index: i64) callconv(.c) i64 {
    const decoded = utf8_at(binary, index) orelse return nil_word;
    return decoded.cp << @intCast(tag_shift);
}

/// Returns the byte width of the UTF-8 codepoint at `index`; 0 for invalid
/// sequences or out-of-range.
pub fn ex_term_binary_utf8_width(binary: i64, index: i64) callconv(.c) i64 {
    const decoded = utf8_at(binary, index) orelse return 0;
    return decoded.width;
}

/// Number of UTF-8 codepoints in a binary; invalid sequences count as one
/// byte each. 0 for non-binaries.
pub fn ex_term_binary_utf8_length(binary: i64) callconv(.c) i64 {
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

fn binaries_equal(left: i64, right: i64) bool {
    const left_len = binary_len(left);
    if (left_len != binary_len(right)) return false;
    for (0..left_len) |index| {
        if (binary_bytes(left)[index] != binary_bytes(right)[index]) return false;
    }
    return true;
}

/// Interns a UTF-8 binary in the current runtime's bounded atom table.
/// Returns integer-zero for invalid input/UTF-8 and tagged integer one when
/// either BEAM's 255-codepoint name limit or the runtime table cap is hit.
pub fn ex_term_string_to_atom(binary: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary) return 0;
    const len: i64 = @intCast(binary_len(binary));
    var codepoints: usize = 0;
    var cursor: i64 = 0;
    while (cursor < len) {
        const decoded = utf8_at(binary, cursor) orelse return 0;
        cursor += decoded.width;
        codepoints += 1;
        if (codepoints > 255) return 1 << @intCast(tag_shift);
    }

    const instance = runtime();
    instance.atom_lock.lock();
    defer instance.atom_lock.unlock();
    for (instance.dynamic_atom_names[0..instance.dynamic_atom_count], 0..) |name, index| {
        if (binaries_equal(name, binary)) return dynamic_atom_word(index);
    }
    if (instance.dynamic_atom_count >= dynamic_atom_cap) return 1 << @intCast(tag_shift);
    const index = instance.dynamic_atom_count;
    instance.dynamic_atom_names[index] = binary;
    instance.dynamic_atom_count += 1;
    return dynamic_atom_word(index);
}

/// Looks up a UTF-8 binary in the current runtime's bounded atom table.
/// Returns integer-zero for invalid input/UTF-8, overlong names, or misses.
pub fn ex_term_string_to_existing_atom(binary: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary) return 0;
    const len: i64 = @intCast(binary_len(binary));
    var codepoints: usize = 0;
    var cursor: i64 = 0;
    while (cursor < len) {
        const decoded = utf8_at(binary, cursor) orelse return 0;
        cursor += decoded.width;
        codepoints += 1;
        if (codepoints > 255) return 0;
    }

    const instance = runtime();
    instance.atom_lock.lock();
    defer instance.atom_lock.unlock();
    for (instance.dynamic_atom_names[0..instance.dynamic_atom_count], 0..) |name, index| {
        if (binaries_equal(name, binary)) return dynamic_atom_word(index);
    }
    return 0;
}

fn printable_codepoint(cp: i64) bool {
    return (cp >= 0x20 and cp <= 0x7E) or
        cp == '\n' or cp == '\r' or cp == '\t' or cp == 0x0B or
        cp == 0x08 or cp == 0x0C or cp == 0x1B or cp == 0x7F or cp == 0x07 or
        (cp >= 0xA0 and cp <= 0xD7FF) or
        (cp >= 0xE000 and cp <= 0xFFFD) or
        (cp >= 0x10000 and cp <= 0x10FFFF);
}

/// Returns whether every UTF-8 codepoint in a binary is printable according
/// to Elixir's String.printable?/1 contract. Invalid UTF-8 and non-binaries
/// return false; the empty binary is printable.
pub fn ex_term_string_printable(binary: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary) return 0;

    const len: i64 = @intCast(binary_len(binary));
    var i: i64 = 0;
    while (i < len) {
        const decoded = utf8_at(binary, i) orelse return 0;
        if (!printable_codepoint(decoded.cp)) return 0;
        i += decoded.width;
    }
    return 1;
}

fn decimal_byte_width(value: u8) usize {
    if (value >= 100) return 3;
    if (value >= 10) return 2;
    return 1;
}

fn write_decimal_byte(out: [*]u8, start: usize, value: u8) usize {
    const width = decimal_byte_width(value);
    var divisor: u16 = if (width == 3) 100 else if (width == 2) 10 else 1;
    var i = start;
    while (divisor > 0) : (divisor /= 10) {
        out[i] = @intCast('0' + (@as(u16, value) / divisor) % 10);
        i += 1;
    }
    return i;
}

fn inspect_escape(cp: i64) ?u8 {
    return switch (cp) {
        0x07 => 'a',
        0x08 => 'b',
        0x09 => 't',
        0x0A => 'n',
        0x0B => 'v',
        0x0C => 'f',
        0x0D => 'r',
        0x1B => 'e',
        0x22 => '"',
        0x5C => '\\',
        0x7F => 'd',
        else => null,
    };
}

/// Renders a binary using the bounded string/binary syntax needed by
/// Kernel.inspect/1. Printable UTF-8 uses quoted string syntax; invalid or
/// non-printable input uses decimal byte syntax (`<<1, 2>>`).
pub fn ex_term_binary_quote(binary: i64) callconv(.c) i64 {
    if (word_tag(binary) != tag_binary) return nil_word;
    const bytes = binary_bytes(binary);
    const len = binary_len(binary);

    if (ex_term_string_printable(binary) == 0) {
        var out_len: usize = 4;
        for (bytes[0..len], 0..) |raw, index| {
            out_len += decimal_byte_width(@intCast(raw & 0xFF));
            if (index > 0) out_len += 2;
        }
        const words = alloc_binary(out_len) orelse return nil_word;
        const result = word_from_ptr(words, tag_binary);
        const out = binary_bytes(result);
        out[0] = '<';
        out[1] = '<';
        var cursor: usize = 2;
        for (bytes[0..len], 0..) |raw, index| {
            if (index > 0) {
                out[cursor] = ',';
                out[cursor + 1] = ' ';
                cursor += 2;
            }
            cursor = write_decimal_byte(out, cursor, @intCast(raw & 0xFF));
        }
        out[cursor] = '>';
        out[cursor + 1] = '>';
        return result;
    }

    var out_len: usize = 2;
    var index: i64 = 0;
    while (index < @as(i64, @intCast(len))) {
        const decoded = utf8_at(binary, index).?;
        if (inspect_escape(decoded.cp) != null) {
            out_len += 2;
        } else if (decoded.cp == 0xA0) {
            out_len += 6;
        } else {
            out_len += @intCast(decoded.width);
        }
        index += decoded.width;
    }

    const words = alloc_binary(out_len) orelse return nil_word;
    const result = word_from_ptr(words, tag_binary);
    const out = binary_bytes(result);
    out[0] = '"';
    var cursor: usize = 1;
    index = 0;
    while (index < @as(i64, @intCast(len))) {
        const decoded = utf8_at(binary, index).?;
        if (inspect_escape(decoded.cp)) |escape| {
            out[cursor] = '\\';
            out[cursor + 1] = escape;
            cursor += 2;
        } else if (decoded.cp == 0xA0) {
            const escaped = "\\u00A0";
            for (escaped) |byte| {
                out[cursor] = byte;
                cursor += 1;
            }
        } else {
            const width: usize = @intCast(decoded.width);
            for (0..width) |offset| out[cursor + offset] = bytes[@as(usize, @intCast(index)) + offset];
            cursor += width;
        }
        index += decoded.width;
    }
    out[cursor] = '"';
    return result;
}

/// Encodes the bytes of a binary as an uppercase hexadecimal binary; nil for
/// non-binaries.
pub fn ex_term_binary_encode16(binary: i64) callconv(.c) i64 {
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
pub fn ex_term_binary_decode16(binary: i64) callconv(.c) i64 {
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

/// Renders a tagged integer term in base 2..36 using uppercase digits; nil
/// for non-integers or an invalid base.
pub fn ex_term_int_to_string_base(word: i64, base: i64) callconv(.c) i64 {
    if (!is_int(word) or base < 2 or base > 36) return nil_word;
    const value = word_payload(word);
    const radix: u64 = @intCast(base);
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    var digits: [64]u8 = undefined;
    var i: usize = 0;
    const negative = value < 0;
    var mag: u64 = @abs(value);
    if (mag == 0) {
        digits[0] = '0';
        i = 1;
    } else {
        while (mag > 0) : (mag /= radix) {
            digits[i] = alphabet[@intCast(mag % radix)];
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

/// Renders a tagged integer term as a decimal binary; nil for non-integers.
pub fn ex_term_int_to_string(word: i64) callconv(.c) i64 {
    return ex_term_int_to_string_base(word, 10);
}

/// Renders a tagged integer term as uppercase hexadecimal with an Elixir
/// `0x` prefix; nil for non-integers.
pub fn ex_term_int_to_hex(word: i64) callconv(.c) i64 {
    if (!is_int(word)) return nil_word;
    const value = word_payload(word);
    const negative = value < 0;
    var magnitude: u64 = @abs(value);
    var digits: [16]u8 = undefined;
    var count: usize = 0;
    const alphabet = "0123456789ABCDEF";
    if (magnitude == 0) {
        digits[0] = '0';
        count = 1;
    } else {
        while (magnitude > 0) : (magnitude /= 16) {
            digits[count] = alphabet[magnitude & 0xF];
            count += 1;
        }
    }
    const out_len = count + 2 + @as(usize, if (negative) 1 else 0);
    const words = alloc_binary(out_len) orelse return nil_word;
    const result = word_from_ptr(words, tag_binary);
    const out = binary_bytes(result);
    var cursor: usize = 0;
    if (negative) {
        out[cursor] = '-';
        cursor += 1;
    }
    out[cursor] = '0';
    out[cursor + 1] = 'x';
    cursor += 2;
    var i = count;
    while (i > 0) {
        i -= 1;
        out[cursor] = digits[i];
        cursor += 1;
    }
    return result;
}

/// Parses a decimal binary (optionally signed) into a scalar i64; 0 for
/// non-binaries, empty or invalid strings, or i64 overflow.
pub fn ex_term_string_to_int(binary: i64) callconv(.c) i64 {
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
pub fn ex_term_map_from_list(list: i64) callconv(.c) i64 {
    const count = list_len(list);
    if (count % 2 != 0) return nil_word;
    const map = alloc_words(1 + count) orelse return nil_word;
    map[0] = @intCast(count / 2);
    copy_list_into(map[1 .. count + 1], list);
    return word_from_ptr(map, tag_map);
}

/// Returns a map with key associated to value, replacing an existing key.
pub fn ex_term_map_put(map: i64, key: i64, value: i64) callconv(.c) i64 {
    if (word_tag(map) != tag_map) return nil_word;
    const len = map_len(map);
    const entries = map_entries(map);
    var pairs = nil_word;
    var found = false;
    var i = len;
    while (i > 0) {
        i -= 1;
        const existing_key = entries[i * 2];
        const existing_value = if (term_eq(existing_key, key)) blk: {
            found = true;
            break :blk value;
        } else entries[i * 2 + 1];
        pairs = ex_term_list_cons(existing_value, pairs);
        pairs = ex_term_list_cons(existing_key, pairs);
    }
    if (!found) {
        pairs = ex_term_list_cons(value, pairs);
        pairs = ex_term_list_cons(key, pairs);
    }
    return ex_term_map_from_list(pairs);
}

/// Merges a list or map enumerable of `{key, value}` pairs into a target map.
/// Entries are applied in enumeration order, so later duplicate keys win.
/// Returns nil for unsupported enumerables, malformed pairs, improper lists,
/// or a non-map target.
pub fn ex_term_enumerable_into_map(enumerable: i64, target: i64) callconv(.c) i64 {
    if (word_tag(target) != tag_map) return nil_word;
    var result = target;

    if (enumerable == nil_word) return result;

    switch (word_tag(enumerable)) {
        tag_list => {
            var current = enumerable;
            while (word_tag(current) == tag_list) {
                const cell = list_cell(current);
                const pair = cell[0];
                if (word_tag(pair) != tag_tuple or tuple_len(pair) != 2) return nil_word;
                const elements = tuple_elems(pair);
                result = ex_term_map_put(result, elements[0], elements[1]);
                if (result == nil_word) return nil_word;
                current = cell[1];
            }
            return if (current == nil_word) result else nil_word;
        },
        tag_map => {
            const len = map_len(enumerable);
            const entries = map_entries(enumerable);
            for (0..len) |i| {
                result = ex_term_map_put(result, entries[i * 2], entries[i * 2 + 1]);
                if (result == nil_word) return nil_word;
            }
            return result;
        },
        else => return nil_word,
    }
}

/// Converts a list of integer byte words into a binary word.
pub fn ex_term_binary_from_list(list: i64) callconv(.c) i64 {
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

fn iodata_size(word: i64, allow_byte: bool, depth: usize) ?usize {
    if (depth > exported_max_depth) return null;

    return switch (word_tag(word)) {
        tag_binary => binary_len(word),
        tag_int => blk: {
            if (!allow_byte) break :blk null;
            const value = word_payload(word);
            break :blk if (value >= 0 and value <= 255) 1 else null;
        },
        tag_atom => if (word == nil_word) 0 else null,
        tag_list => blk: {
            var total: usize = 0;
            var current = word;
            while (word_tag(current) == tag_list) {
                const cell = list_cell(current);
                const child = iodata_size(cell[0], true, depth + 1) orelse break :blk null;
                total = std.math.add(usize, total, child) catch break :blk null;
                current = cell[1];
            }
            const tail = iodata_size(current, false, depth + 1) orelse break :blk null;
            break :blk std.math.add(usize, total, tail) catch null;
        },
        else => null,
    };
}

fn write_iodata(word: i64, output: []u8, offset: *usize, allow_byte: bool, depth: usize) bool {
    if (depth > exported_max_depth) return false;

    switch (word_tag(word)) {
        tag_binary => {
            const len = binary_len(word);
            @memcpy(output[offset.*..][0..len], binary_bytes(word)[0..len]);
            offset.* += len;
            return true;
        },
        tag_int => {
            if (!allow_byte) return false;
            const value = word_payload(word);
            if (value < 0 or value > 255) return false;
            output[offset.*] = @intCast(value);
            offset.* += 1;
            return true;
        },
        tag_atom => return word == nil_word,
        tag_list => {
            var current = word;
            while (word_tag(current) == tag_list) {
                const cell = list_cell(current);
                if (!write_iodata(cell[0], output, offset, true, depth + 1)) return false;
                current = cell[1];
            }
            return write_iodata(current, output, offset, false, depth + 1);
        },
        else => return false,
    }
}

/// Flattens nested byte lists and binaries, including a binary improper tail.
pub fn ex_term_iodata_to_binary(iodata: i64) callconv(.c) i64 {
    if (word_tag(iodata) == tag_binary) return iodata;
    const len = iodata_size(iodata, false, 0) orelse return nil_word;
    const binary = alloc_binary(len) orelse return nil_word;
    const result = word_from_ptr(binary, tag_binary);
    var offset: usize = 0;
    if (!write_iodata(iodata, binary_bytes(result)[0..len], &offset, false, 0)) return nil_word;
    return result;
}

pub fn ex_term_is_integer(word: i64) callconv(.c) i64 {
    return if (is_int(word) or is_bigint(word)) 1 else 0;
}

pub fn ex_term_is_atom(word: i64) callconv(.c) i64 {
    return if (is_atom(word)) 1 else 0;
}

pub fn ex_term_is_binary(word: i64) callconv(.c) i64 {
    return if (word_tag(word) == tag_binary) 1 else 0;
}

pub fn ex_term_is_list(word: i64) callconv(.c) i64 {
    return if (is_list_word(word)) 1 else 0;
}

pub fn ex_term_is_tuple(word: i64) callconv(.c) i64 {
    return if (word_tag(word) == tag_tuple) 1 else 0;
}

pub fn ex_term_is_map(word: i64) callconv(.c) i64 {
    return if (word_tag(word) == tag_map) 1 else 0;
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

test "boxed floats share tag 7 without colliding with runtime-local words" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    const value = ex_term_float_lit(@bitCast(@as(u64, @bitCast(@as(f64, -0.0)))));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_float(value));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast(ex_term_float_bits(value))));
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_float(runtime_local_word(runtime_local_ref, 42)));
    try std.testing.expectEqual(@as(i64, 0), ex_term_float_bits(1));
}

test "boxed integer literals preserve canonical arbitrary precision equality" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    const immediate = ex_term_bigint_lit(test_binary_from_string("1152921504606846975"));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_integer(immediate));
    try std.testing.expectEqual(@as(i64, 1152921504606846975) * 8, immediate);

    const positive = ex_term_bigint_lit(test_binary_from_string("1152921504606846976"));
    const positive_copy = ex_term_bigint_lit(test_binary_from_string("1152921504606846976"));
    const negative = ex_term_bigint_lit(test_binary_from_string("-1152921504606846977"));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_integer(positive));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_integer(negative));
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_float(positive));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(positive, positive_copy));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq_loose(positive, positive_copy));
    try std.testing.expectEqual(@as(i64, 0), ex_term_eq(positive, negative));

    for ([_][]const u8{ "", "-", "01", "-01", "+1", "1.0" }) |invalid| {
        try std.testing.expectEqual(
            @as(i64, 1),
            ex_term_is_nil_word(ex_term_bigint_lit(test_binary_from_string(invalid))),
        );
    }
}

test "string to float preserves finite binary64 values and rejects invalid syntax" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    const value = ex_term_string_to_float(test_binary_from_string("12.5"));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_float(value));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 12.5))), float_bits(value));

    const overflow = ex_term_string_to_float(test_binary_from_string("1.0e400"));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(overflow));

    for ([_][]const u8{ "1", "1e2", "1.", ".5", "1.0e", "NaN" }) |invalid| {
        const parsed = ex_term_string_to_float(test_binary_from_string(invalid));
        try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(parsed));
    }
}

test "string to atom validates UTF-8 and interns within the runtime" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    const alpha = ex_term_string_to_atom(test_binary_from_string("alpha"));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_atom(alpha));
    try std.testing.expect(dynamic_atom_index(alpha) != null);
    try std.testing.expectEqual(alpha, ex_term_string_to_atom(test_binary_from_string("alpha")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_atom(ex_term_string_to_atom(test_binary_from_string("λ"))));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_atom(ex_term_string_to_atom(test_binary_from_string(""))));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_to_atom(42 << @intCast(tag_shift)));

    const invalid = alloc_binary(1).?;
    const invalid_word = word_from_ptr(invalid, tag_binary);
    binary_bytes(invalid_word)[0] = 0xFF;
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_to_atom(invalid_word));

    const oversized = alloc_binary(256).?;
    const oversized_word = word_from_ptr(oversized, tag_binary);
    @memset(binary_bytes(oversized_word)[0..256], 'a');
    try std.testing.expectEqual(@as(i64, 8), ex_term_string_to_atom(oversized_word));
}

test "string to existing atom only queries the runtime atom table" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    const alpha_name = test_binary_from_string("alpha");
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_to_existing_atom(alpha_name));
    const alpha = ex_term_string_to_atom(alpha_name);
    try std.testing.expectEqual(alpha, ex_term_string_to_existing_atom(alpha_name));

    const unicode_name = test_binary_from_string("λ");
    const unicode = ex_term_string_to_atom(unicode_name);
    try std.testing.expectEqual(unicode, ex_term_string_to_existing_atom(unicode_name));

    try std.testing.expectEqual(@as(i64, 0), ex_term_string_to_existing_atom(42 << @intCast(tag_shift)));

    const invalid = alloc_binary(1).?;
    const invalid_word = word_from_ptr(invalid, tag_binary);
    binary_bytes(invalid_word)[0] = 0xFF;
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_to_existing_atom(invalid_word));

    const oversized = alloc_binary(256).?;
    const oversized_word = word_from_ptr(oversized, tag_binary);
    @memset(binary_bytes(oversized_word)[0..256], 'a');
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_to_existing_atom(oversized_word));
}

test "short float formatting matches Erlang decimal and exponent boundaries" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = 0.0, .expected = "0.0" },
        .{ .value = -0.0, .expected = "-0.0" },
        .{ .value = 0.1, .expected = "0.1" },
        .{ .value = 12.5, .expected = "12.5" },
        .{ .value = 100.0, .expected = "100.0" },
        .{ .value = 1000.0, .expected = "1.0e3" },
        .{ .value = 1230.0, .expected = "1230.0" },
        .{ .value = 1200.0, .expected = "1.2e3" },
        .{ .value = 0.0001, .expected = "0.0001" },
        .{ .value = 0.00001, .expected = "1.0e-5" },
        .{ .value = 1234567890123456.0, .expected = "1234567890123456.0" },
        .{ .value = 9007199254740991.0, .expected = "9007199254740991.0" },
        .{ .value = 9007199254740992.0, .expected = "9.007199254740992e15" },
        .{ .value = 1.234567890123456e16, .expected = "1.234567890123456e16" },
        .{ .value = 6.926449721417386e17, .expected = "6.926449721417386e17" },
        .{ .value = 5.0e-324, .expected = "5.0e-324" },
        .{ .value = 2.2250738585072014e-308, .expected = "2.2250738585072014e-308" },
        .{ .value = 1.7976931348623157e308, .expected = "1.7976931348623157e308" },
    };

    for (cases) |case| {
        const value = ex_term_float_lit(@bitCast(@as(u64, @bitCast(case.value))));
        const rendered = ex_term_float_to_binary_short(value);
        try std.testing.expectEqualSlices(u8, case.expected, binary_bytes(rendered)[0..binary_len(rendered)]);
    }

    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_float_to_binary_short(1 << @intCast(tag_shift))));
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

    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_int_to_string_base(forty_two, 2), test_binary_from_string("101010")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_int_to_string_base(forty_two, 16), test_binary_from_string("2A")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_int_to_string_base(35 << @intCast(tag_shift), 36), test_binary_from_string("Z")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_int_to_string_base(-255 << @intCast(tag_shift), 16), test_binary_from_string("-FF")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_int_to_string_base(forty_two, 1)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_int_to_string_base(forty_two, 37)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_int_to_string_base(test_binary_from_string("42"), 10)));
}

test "closure ABI carries arity without breaking legacy env reads" {
    const legacy = ex_term_make_fun(11, 2, 21, 22, 0, 0);
    try std.testing.expectEqual(@as(i64, 11), ex_term_fun_idx(legacy));
    try std.testing.expectEqual(@as(i64, -1), ex_term_fun_arity(legacy));
    try std.testing.expectEqual(@as(i64, 21), ex_term_fun_env(legacy, 0));
    try std.testing.expectEqual(@as(i64, 22), ex_term_fun_env(legacy, 1));

    const arity_carrying = ex_term_make_fun_with_arity(12, 1, 2, 31, 32, 0, 0);
    try std.testing.expectEqual(@as(i64, 12), ex_term_fun_idx(arity_carrying));
    try std.testing.expectEqual(@as(i64, 1), ex_term_fun_arity(arity_carrying));
    try std.testing.expectEqual(@as(i64, 31), ex_term_fun_env(arity_carrying, 0));
    try std.testing.expectEqual(@as(i64, 32), ex_term_fun_env(arity_carrying, 1));
    try std.testing.expectEqual(nil_word, ex_term_fun_env(arity_carrying, 2));
    try std.testing.expectEqual(@as(i64, -1), ex_term_fun_arity(nil_word));

    const signed = ex_term_make_fun_with_signature(13, 1, 1, 2, 41, 42, 0, 0);
    try std.testing.expectEqual(@as(i64, 13), ex_term_fun_idx(signed));
    try std.testing.expectEqual(@as(i64, 1), ex_term_fun_arity(signed));
    try std.testing.expectEqual(@as(i64, 1), ex_term_fun_result_mode(signed));
    try std.testing.expectEqual(@as(i64, 41), ex_term_fun_env(signed, 0));
    try std.testing.expectEqual(@as(i64, 42), ex_term_fun_env(signed, 1));
    try std.testing.expectEqual(@as(i64, -1), ex_term_fun_result_mode(arity_carrying));
}

test "list flatten preserves leaves and rejects improper nested lists" {
    const one = @as(i64, 1 << 3);
    const two = @as(i64, 2 << 3);
    const three = @as(i64, 3 << 3);
    const binary = test_binary_from_string("leaf");
    const nested = ex_term_list_cons(
        one,
        ex_term_list_cons(
            ex_term_list_cons(two, ex_term_list_cons(nil_word, nil_word)),
            ex_term_list_cons(binary, ex_term_list_cons(three, nil_word)),
        ),
    );

    const flattened = ex_term_list_flatten(nested);
    try std.testing.expectEqual(@as(i64, 4), ex_term_list_length(flattened));
    try std.testing.expectEqual(one, ex_term_list_head(flattened));
    try std.testing.expectEqual(two, ex_term_list_get(flattened, 1));
    try std.testing.expectEqual(binary, ex_term_list_get(flattened, 2));
    try std.testing.expectEqual(three, ex_term_list_get(flattened, 3));
    try std.testing.expectEqual(nil_word, ex_term_list_flatten(nil_word));

    const improper = ex_term_list_cons(one, two);
    const nested_improper = ex_term_list_cons(improper, nil_word);
    try std.testing.expectEqual(@as(i64, 0), ex_term_list_flatten(improper));
    try std.testing.expectEqual(@as(i64, 0), ex_term_list_flatten(nested_improper));
    try std.testing.expectEqual(@as(i64, 0), ex_term_list_flatten(one));
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

    const null_list_word: i64 = @intCast(tag_list);
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_list(null_list_word));
    try std.testing.expectEqual(@as(i64, 0), ex_term_list_length(null_list_word));
    try std.testing.expectEqual(nil_word, ex_term_list_head(null_list_word));
    try std.testing.expectEqual(nil_word, ex_term_list_tail(null_list_word));
    try std.testing.expectEqual(nil_word, ex_term_list_get(null_list_word, 0));

    // map reads
    const entries = ex_term_list_cons(one, ex_term_list_cons(two, nil_word));
    const map = ex_term_map_from_list(entries);
    try std.testing.expectEqual(@as(i64, 1), ex_term_map_length(map));
    try std.testing.expectEqual(@as(i64, 0), ex_term_map_length(one));

    const found = ex_term_map_fetch(map, one);
    try std.testing.expectEqual(@as(i64, 1), ex_term_to_int(ex_term_tuple_get(found, 0)));
    try std.testing.expectEqual(two, ex_term_tuple_get(found, 1));

    const missing = ex_term_map_fetch(map, two);
    try std.testing.expectEqual(@as(i64, 0), ex_term_to_int(ex_term_tuple_get(missing, 0)));
    try std.testing.expectEqual(nil_word, ex_term_tuple_get(missing, 1));

    const nil_map = ex_term_map_from_list(ex_term_list_cons(one, ex_term_list_cons(nil_word, nil_word)));
    const found_nil = ex_term_map_fetch(nil_map, one);
    try std.testing.expectEqual(@as(i64, 1), ex_term_to_int(ex_term_tuple_get(found_nil, 0)));
    try std.testing.expectEqual(nil_word, ex_term_tuple_get(found_nil, 1));

    const non_map = ex_term_map_fetch(one, one);
    try std.testing.expectEqual(@as(i64, 0), ex_term_to_int(ex_term_tuple_get(non_map, 0)));
    try std.testing.expectEqual(nil_word, ex_term_tuple_get(non_map, 1));

    // Enum.into/2 map collection: later list pairs override defaults and
    // duplicate keys, while map enumerables add their own pairs.
    const three: i64 = 24;
    const four: i64 = 32;
    const pair_one_three = tuple2(one, three);
    const pair_one_four = tuple2(one, four);
    const pair_two_three = tuple2(two, three);
    const pairs = ex_term_list_cons(pair_one_three, ex_term_list_cons(pair_one_four, ex_term_list_cons(pair_two_three, nil_word)));
    const merged = ex_term_enumerable_into_map(pairs, map);
    try std.testing.expectEqual(@as(i64, 2), ex_term_map_length(merged));
    try std.testing.expectEqual(four, ex_term_tuple_get(ex_term_map_fetch(merged, one), 1));
    try std.testing.expectEqual(three, ex_term_tuple_get(ex_term_map_fetch(merged, two), 1));
    try std.testing.expectEqual(map, ex_term_enumerable_into_map(nil_word, map));

    const source_map = ex_term_map_from_list(ex_term_list_cons(two, ex_term_list_cons(four, nil_word)));
    const merged_map = ex_term_enumerable_into_map(source_map, map);
    try std.testing.expectEqual(four, ex_term_tuple_get(ex_term_map_fetch(merged_map, two), 1));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_enumerable_into_map(list, map)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_enumerable_into_map(pairs, one)));

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
    const separator = 99 << @intCast(tag_shift);
    const interspersed = ex_term_enumerable_intersperse(list, separator);
    try std.testing.expectEqual(@as(i64, 3), ex_term_list_length(interspersed));
    try std.testing.expectEqual(one, ex_term_list_head(interspersed));
    try std.testing.expectEqual(separator, ex_term_list_head(ex_term_list_tail(interspersed)));
    try std.testing.expectEqual(two, ex_term_list_head(ex_term_list_tail(ex_term_list_tail(interspersed))));
    try std.testing.expectEqual(nil_word, ex_term_enumerable_intersperse(nil_word, separator));
    const singleton = ex_term_list_cons(one, nil_word);
    const singleton_result = ex_term_enumerable_intersperse(singleton, separator);
    try std.testing.expectEqual(@as(i64, 1), ex_term_list_length(singleton_result));
    try std.testing.expectEqual(one, ex_term_list_head(singleton_result));
    try std.testing.expectEqual(@as(i64, 3), ex_term_list_length(ex_term_enumerable_intersperse(tuple, separator)));
    try std.testing.expectEqual(@as(i64, 5), ex_term_list_length(ex_term_enumerable_intersperse(count_bin, separator)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_list_length(ex_term_enumerable_intersperse(map, separator)));
    try std.testing.expectEqual(nil_word, ex_term_enumerable_intersperse(one, separator));
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

    const mapped_terms = ex_term_enumerable_map_term_fun(list, &test_mapper_identity_term);
    try std.testing.expectEqual(one, ex_term_list_head(mapped_terms));
    try std.testing.expectEqual(two, ex_term_list_head(ex_term_list_tail(mapped_terms)));

    const captured_terms = ex_term_enumerable_map_term_fun_c(
        list,
        &test_mapper_pair_with_capture,
        9 << @intCast(tag_shift),
        0,
        0,
        0,
    );
    const captured_first = ex_term_list_head(captured_terms);
    try std.testing.expectEqual(one, ex_term_tuple_get(captured_first, 0));
    try std.testing.expectEqual(@as(i64, 9 << @intCast(tag_shift)), ex_term_tuple_get(captured_first, 1));

    const flat_mapped_terms = ex_term_enumerable_flat_map_term_fun(list, &test_mapper_duplicate_term);
    try std.testing.expectEqual(@as(i64, 4), ex_term_list_length(flat_mapped_terms));
    try std.testing.expectEqual(one, ex_term_list_head(flat_mapped_terms));
    try std.testing.expectEqual(one, ex_term_list_head(ex_term_list_tail(flat_mapped_terms)));

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

    // loose equality coerces integer/float values recursively without
    // rounding large, non-representable integers into false matches.
    const one_float = ex_term_float_lit(@bitCast(@as(f64, 1.0)));
    try std.testing.expectEqual(@as(i64, 0), ex_term_eq(one, one_float));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq_loose(one, one_float));
    const tuple_float = ex_term_tuple_from_list(ex_term_list_cons(one_float, nil_word));
    const tuple_int = ex_term_tuple_from_list(ex_term_list_cons(one, nil_word));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq_loose(tuple_int, tuple_float));
    const rounded_int = @as(i64, 9_007_199_254_740_993) << @intCast(tag_shift);
    const rounded_float = ex_term_float_lit(@bitCast(@as(f64, 9_007_199_254_740_992.0)));
    try std.testing.expectEqual(@as(i64, 0), ex_term_eq_loose(rounded_int, rounded_float));

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

    const part = ex_term_binary_part(binary, 0, one);
    try std.testing.expectEqual(@as(i64, 1), ex_term_binary_length(part));
    try std.testing.expectEqual(one, ex_term_binary_get(part, 0));
    const preceding = ex_term_binary_part(binary, two, -one);
    try std.testing.expectEqual(two, ex_term_binary_get(preceding, 0));
    try std.testing.expectEqual(@as(i64, 0), ex_term_binary_length(ex_term_binary_part(binary, two, 0)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_binary_part(binary, one, two)));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_binary_part(binary, nil_word, one)));

    // Binary enumeration widens bytes before applying the three-bit term
    // tag. Shifting as u8 truncated every value at or above 32.
    const high_bytes = ex_term_list_cons(
        @as(i64, 48 << 3),
        ex_term_list_cons(@as(i64, 255 << 3), nil_word),
    );
    const high_binary = ex_term_binary_from_list(high_bytes);
    const materialized_bytes = ex_term_enumerable_to_list(high_binary);
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(high_bytes, materialized_bytes));

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

fn test_mapper_identity_term(item: i64) callconv(.c) i64 {
    return item;
}

fn test_mapper_pair_with_capture(
    env0: i64,
    _: i64,
    _: i64,
    _: i64,
    item: i64,
    _: i64,
    _: i64,
    _: i64,
) callconv(.c) i64 {
    return ex_term_tuple_from_list(ex_term_list_cons(item, ex_term_list_cons(env0, nil_word)));
}

fn test_mapper_duplicate_term(item: i64) callconv(.c) i64 {
    return ex_term_list_cons(item, ex_term_list_cons(item, nil_word));
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

fn test_pattern_byte(index: usize) u8 {
    return @intCast((index * 131 + 255) % 256);
}

fn test_pattern_byte_list(len: usize) i64 {
    var list = nil_word;
    var i = len;
    while (i > 0) {
        i -= 1;
        list = ex_term_list_cons(
            @as(i64, test_pattern_byte(i)) << @intCast(tag_shift),
            list,
        );
    }
    return list;
}

test "binary and list conversions preserve boundary sizes and high bytes" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    const sizes = [_]usize{
        0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 255, 256, 257, 1024, 4096, 65536,
    };

    for (sizes) |len| {
        const list = test_pattern_byte_list(len);
        const binary = ex_term_binary_from_list(list);
        try std.testing.expectEqual(@as(i64, @intCast(len)), ex_term_binary_length(binary));

        const materialized = ex_term_enumerable_to_list(binary);
        try std.testing.expectEqual(@as(i64, @intCast(len)), ex_term_list_length(materialized));
        try std.testing.expectEqual(@as(i64, 1), ex_term_eq(list, materialized));
        try std.testing.expectEqual(
            @as(i64, 1),
            ex_term_eq(binary, ex_term_binary_from_list(materialized)),
        );

        const full_slice = ex_term_binary_slice(binary, 0);
        try std.testing.expectEqual(@as(i64, 1), ex_term_eq(binary, full_slice));
        const empty_slice = ex_term_binary_slice(binary, @intCast(len));
        try std.testing.expectEqual(@as(i64, 0), ex_term_binary_length(empty_slice));

        if (len > 0) {
            const last_index: i64 = @intCast(len - 1);
            try std.testing.expectEqual(
                @as(i64, test_pattern_byte(0)) << @intCast(tag_shift),
                ex_term_binary_get(binary, 0),
            );
            try std.testing.expectEqual(
                @as(i64, test_pattern_byte(len - 1)) << @intCast(tag_shift),
                ex_term_binary_get(binary, last_index),
            );

            const midpoint: i64 = @intCast(len / 2);
            const suffix = ex_term_binary_slice(binary, midpoint);
            try std.testing.expectEqual(
                @as(i64, @intCast(len - len / 2)),
                ex_term_binary_length(suffix),
            );
            try std.testing.expectEqual(
                ex_term_binary_get(binary, midpoint),
                ex_term_binary_get(suffix, 0),
            );
        }
    }
}

test "iodata conversion preserves bounded nesting and binary improper tails" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    var nested = test_binary_from_string("tail");
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        nested = ex_term_list_cons(
            @as(i64, 'a' + @as(u8, @intCast(depth))) << @intCast(tag_shift),
            ex_term_list_cons(nested, nil_word),
        );
    }

    const flattened = ex_term_iodata_to_binary(nested);
    try std.testing.expectEqual(@as(i64, 12), ex_term_binary_length(flattened));
    try std.testing.expectEqual(@as(i64, 'h' << 3), ex_term_binary_get(flattened, 0));
    try std.testing.expectEqual(@as(i64, 't' << 3), ex_term_binary_get(flattened, 8));

    const improper = ex_term_list_cons(
        @as(i64, 0) << @intCast(tag_shift),
        test_binary_from_string("\x01\x7F\x80\xFF"),
    );
    const improper_flattened = ex_term_iodata_to_binary(improper);
    try std.testing.expectEqual(@as(i64, 5), ex_term_binary_length(improper_flattened));
    try std.testing.expectEqual(@as(i64, 0), ex_term_binary_get(improper_flattened, 0));
    try std.testing.expectEqual(@as(i64, 255 << 3), ex_term_binary_get(improper_flattened, 4));
}

test "string printable follows Elixir UTF-8 and control character boundaries" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string("")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string(" ~")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string("\x07\x08\t\n\x0B\x0C\r\x1B\x7F")));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(test_binary_from_string("\x00")));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(test_binary_from_string("\x1F")));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(test_binary_from_string("\xC2\x80")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string("\xC2\xA0")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string("\xED\x9F\xBF")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string("\xEE\x80\x80")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string("\xEF\xBF\xBD")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string("\xF0\x90\x80\x80")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_string_printable(test_binary_from_string("\xF4\x8F\xBF\xBF")));

    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(test_binary_from_string("\xFF")));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(test_binary_from_string("\xC0\xAF")));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(test_binary_from_string("\xE2\x82")));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(test_binary_from_string("\xED\xA0\x80")));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(test_binary_from_string("\xF4\x90\x80\x80")));
    try std.testing.expectEqual(@as(i64, 0), ex_term_string_printable(@as(i64, 1) << @intCast(tag_shift)));
}

test "bounded inspect format primitives match Elixir syntax" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_int_to_hex(0 << @intCast(tag_shift)), test_binary_from_string("0x0")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_int_to_hex(255 << @intCast(tag_shift)), test_binary_from_string("0xFF")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_int_to_hex(-255 << @intCast(tag_shift)), test_binary_from_string("-0xFF")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_int_to_hex(test_binary_from_string("1"))));

    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("ab")), test_binary_from_string("\"ab\"")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("a\"b")), test_binary_from_string("\"a\\\"b\"")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("a\\b")), test_binary_from_string("\"a\\\\b\"")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("a\nb")), test_binary_from_string("\"a\\nb\"")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("\xC3\xA9")), test_binary_from_string("\"\xC3\xA9\"")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("\xC2\xA0")), test_binary_from_string("\"\\u00A0\"")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("\x00")), test_binary_from_string("<<0>>")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("\xFF")), test_binary_from_string("<<255>>")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_eq(ex_term_binary_quote(test_binary_from_string("\x01\x02")), test_binary_from_string("<<1, 2>>")));
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_binary_quote(1 << @intCast(tag_shift))));
}

test "iodata flatten handles nested lists and binary improper tails" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(handle);
    }

    const inner = ex_term_list_cons(@as(i64, 'b') << @intCast(tag_shift), ex_term_list_cons(test_binary_from_string("c"), nil_word));
    const nested = ex_term_list_cons(test_binary_from_string("a"), ex_term_list_cons(inner, nil_word));
    const flattened = ex_term_iodata_to_binary(nested);
    try std.testing.expectEqual(@as(usize, 3), binary_len(flattened));
    try std.testing.expectEqualSlices(u8, "abc", binary_bytes(flattened)[0..3]);

    const improper = ex_term_list_cons(@as(i64, 'a') << @intCast(tag_shift), test_binary_from_string("bc"));
    const improper_flattened = ex_term_iodata_to_binary(improper);
    try std.testing.expectEqualSlices(u8, "abc", binary_bytes(improper_flattened)[0..3]);

    const invalid = ex_term_list_cons(@as(i64, 256) << @intCast(tag_shift), nil_word);
    try std.testing.expectEqual(@as(i64, 1), ex_term_is_nil_word(ex_term_iodata_to_binary(invalid)));
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
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_atom(pid));
    try std.testing.expect(is_pid(pid));

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
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_atom(pid2));
    try std.testing.expect(is_pid(pid2));
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
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(first));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(second));
}

const CompetingEnterProbe = struct {
    handle: i64,
    result: std.atomic.Value(i64) = .init(99),

    fn run(self: *@This()) void {
        self.result.store(ex_term_runtime_enter(self.handle), .release);
    }
};

const WorkerLeaseProbe = struct {
    instance: *Runtime,
    handle: i64,
    epoch: u64,
    ready: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    left: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        if (!worker_join(self.instance, self.handle, self.epoch)) return;
        self.ready.store(true, .release);
        while (!self.release.load(.acquire)) std.Thread.yield() catch {};
        self.left.store(worker_leave(), .release);
    }
};

const OwnerLeaveGateProbe = struct {
    handle: std.atomic.Value(i64) = .init(0),
    leave_result: std.atomic.Value(i64) = .init(99),

    fn run(self: *@This()) void {
        const handle = ex_term_runtime_create();
        self.handle.store(handle, .release);
        if (ex_term_runtime_enter(handle) != 0) return;
        self.leave_result.store(ex_term_runtime_leave(), .release);
    }
};

test "lifecycle race gate captures a deterministic linearization snapshot" {
    const gate = &LifecycleTestState.gate;
    gate.arm(.runtime_leave_committed, "harness-leave-commit", 0x60_01);
    defer gate.disarm();

    var probe = OwnerLeaveGateProbe{};
    const thread = try std.Thread.spawn(.{}, OwnerLeaveGateProbe.run, .{&probe});
    var joined = false;
    defer {
        gate.release();
        if (!joined) thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    try std.testing.expectEqual(LifecyclePhase.idle, gate.snapshot.phase);
    try std.testing.expectEqual(@as(i64, 0), gate.snapshot.execution_handle);
    try std.testing.expectEqual(@as(usize, 0), gate.snapshot.owner);
    try std.testing.expectEqual(@as(u32, 0), gate.snapshot.participants);
    try std.testing.expect(!gate.snapshot.initialized);
    try std.testing.expectEqual(@as(u32, 0), gate.snapshot.results);
    try std.testing.expectEqual(@as(u32, 0), gate.snapshot.terms);

    const handle = probe.handle.load(.acquire);
    try std.testing.expect(handle != 0);
    gate.release();
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(i64, 0), probe.leave_result.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

const ScalarResultFixture = struct {
    runtime: i64,
    result: i64,
    word: i64,
};

fn createScalarResultFixture() ScalarResultFixture {
    const runtime_handle = ex_term_runtime_create();
    std.debug.assert(runtime_handle > 0);
    std.debug.assert(ex_term_runtime_enter(runtime_handle) == 0);
    std.debug.assert(ex_term_process_table_reset(default_process_cap) == 1);
    const word: i64 = 56;
    const result = ex_term_result_create(runtime_handle, word);
    std.debug.assert(result > 0);
    std.debug.assert(ex_term_runtime_leave() == 0);
    return .{ .runtime = runtime_handle, .result = result, .word = word };
}

const PortableTermFixture = struct {
    runtime: i64,
    term: i64,
    exported: i64,
};

fn createPortableTermFixture() PortableTermFixture {
    const source = createScalarResultFixture();
    const exported = ex_term_export(source.result, source.word);
    std.debug.assert(exported > 0);
    std.debug.assert(ex_term_result_destroy(source.result) == 0);

    const runtime_handle = ex_term_runtime_create();
    std.debug.assert(ex_term_runtime_enter(runtime_handle) == 0);
    const term = ex_term_import(runtime_handle, exported);
    std.debug.assert(term > 0);
    std.debug.assert(ex_term_runtime_leave() == 0);
    return .{ .runtime = runtime_handle, .term = term, .exported = exported };
}

const LifecycleCall = enum {
    result_export,
    term_export,
    result_destroy,
    term_destroy,
    runtime_destroy,
};

const LifecycleCallProbe = struct {
    call: LifecycleCall,
    first: i64,
    second: i64 = 0,
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: std.atomic.Value(i64) = .init(99),

    fn run(self: *@This()) void {
        self.started.store(true, .release);
        const result = switch (self.call) {
            .result_export => ex_term_export(self.first, self.second),
            .term_export => ex_term_handle_export(self.first),
            .result_destroy => ex_term_result_destroy(self.first),
            .term_destroy => ex_term_handle_destroy(self.first),
            .runtime_destroy => ex_term_runtime_destroy(self.first),
        };
        self.result.store(result, .release);
        self.done.store(true, .release);
    }
};

fn waitLifecycleFlag(flag: *std.atomic.Value(bool), case_name: []const u8, seed: u64) bool {
    for (0..10_000_000) |_| {
        if (flag.load(.acquire)) return true;
        std.Thread.yield() catch {};
    }
    std.debug.print("lifecycle race timeout: case={s} seed={d} phase=worker-start\n", .{ case_name, seed });
    return false;
}

test "result export lease excludes enter and destroy until the copy completes" {
    const fixture = createScalarResultFixture();
    const gate = &LifecycleTestState.gate;
    gate.arm(.result_export_committed, "result-export-exclusive", 0x60_02);
    defer gate.disarm();

    var export_probe = LifecycleCallProbe{
        .call = .result_export,
        .first = fixture.result,
        .second = fixture.word,
    };
    const thread = try std.Thread.spawn(.{}, LifecycleCallProbe.run, .{&export_probe});
    var joined = false;
    defer {
        gate.release();
        if (!joined) thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    try std.testing.expectEqual(LifecyclePhase.exporting, gate.snapshot.phase);
    try std.testing.expectEqual(@as(u32, 1), gate.snapshot.results);
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_enter(fixture.runtime));
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_destroy(fixture.runtime));
    try std.testing.expectEqual(@as(i64, -2), ex_term_result_destroy(fixture.result));

    gate.release();
    thread.join();
    joined = true;
    const exported = export_probe.result.load(.acquire);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(fixture.result));
}

test "term export lease survives handle destroy and excludes runtime destroy" {
    const fixture = createPortableTermFixture();
    const gate = &LifecycleTestState.gate;
    gate.arm(.term_export_committed, "term-export-handle-destroy", 0x60_03);
    defer gate.disarm();

    var export_probe = LifecycleCallProbe{ .call = .term_export, .first = fixture.term };
    const thread = try std.Thread.spawn(.{}, LifecycleCallProbe.run, .{&export_probe});
    var joined = false;
    defer {
        gate.release();
        if (!joined) thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    try std.testing.expectEqual(LifecyclePhase.exporting, gate.snapshot.phase);
    try std.testing.expectEqual(@as(u32, 1), gate.snapshot.terms);
    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(fixture.term));
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_destroy(fixture.runtime));

    gate.release();
    thread.join();
    joined = true;
    const copy = export_probe.result.load(.acquire);
    try std.testing.expect(copy > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(fixture.runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(copy));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(fixture.exported));
}

const OwnerResultLeaveProbe = struct {
    runtime: std.atomic.Value(i64) = .init(0),
    result: std.atomic.Value(i64) = .init(0),
    leave_result: std.atomic.Value(i64) = .init(99),

    fn run(self: *@This()) void {
        const runtime_handle = ex_term_runtime_create();
        if (runtime_handle <= 0 or ex_term_runtime_enter(runtime_handle) != 0) return;
        if (ex_term_process_table_reset(default_process_cap) != 1) return;
        const result = ex_term_result_create(runtime_handle, 64);
        self.runtime.store(runtime_handle, .release);
        self.result.store(result, .release);
        self.leave_result.store(ex_term_runtime_leave(), .release);
    }
};

test "leave to idle linearizes before result export begins" {
    const gate = &LifecycleTestState.gate;
    gate.arm(.runtime_leave_committed, "leave-before-export", 0x60_04);
    defer gate.disarm();

    var owner = OwnerResultLeaveProbe{};
    const thread = try std.Thread.spawn(.{}, OwnerResultLeaveProbe.run, .{&owner});
    var joined = false;
    defer {
        gate.release();
        if (!joined) thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    try std.testing.expectEqual(LifecyclePhase.idle, gate.snapshot.phase);
    try std.testing.expectEqual(@as(u32, 1), gate.snapshot.results);
    const result = owner.result.load(.acquire);
    const exported = ex_term_export(result, 64);
    try std.testing.expect(exported > 0);

    gate.release();
    thread.join();
    joined = true;
    try std.testing.expectEqual(@as(i64, 0), owner.leave_result.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(result));
}

test "result destroy revalidates after a concurrent export" {
    const fixture = createScalarResultFixture();
    const gate = &LifecycleTestState.gate;
    gate.arm(.result_destroy_snapshotted, "result-destroy-revalidate", 0x60_05);
    defer gate.disarm();

    var destroy_probe = LifecycleCallProbe{ .call = .result_destroy, .first = fixture.result };
    const thread = try std.Thread.spawn(.{}, LifecycleCallProbe.run, .{&destroy_probe});
    var joined = false;
    defer {
        gate.release();
        if (!joined) thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    const exported = ex_term_export(fixture.result, fixture.word);
    try std.testing.expect(exported > 0);
    gate.release();
    thread.join();
    joined = true;

    try std.testing.expectEqual(@as(i64, 0), destroy_probe.result.load(.acquire));
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_destroy(fixture.result));
    try std.testing.expect(ex_term_exported_length(exported) > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

test "term destroy revalidates after a concurrent export" {
    const fixture = createPortableTermFixture();
    const gate = &LifecycleTestState.gate;
    gate.arm(.term_destroy_snapshotted, "term-destroy-revalidate", 0x60_06);
    defer gate.disarm();

    var destroy_probe = LifecycleCallProbe{ .call = .term_destroy, .first = fixture.term };
    const thread = try std.Thread.spawn(.{}, LifecycleCallProbe.run, .{&destroy_probe});
    var joined = false;
    defer {
        gate.release();
        if (!joined) thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    const copy = ex_term_handle_export(fixture.term);
    try std.testing.expect(copy > 0);
    gate.release();
    thread.join();
    joined = true;

    try std.testing.expectEqual(@as(i64, 0), destroy_probe.result.load(.acquire));
    try std.testing.expectEqual(@as(i64, -1), ex_term_handle_destroy(fixture.term));
    try std.testing.expect(ex_term_exported_length(copy) > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(fixture.runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(copy));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(fixture.exported));
}

const ImportLeaveProbe = struct {
    runtime: i64,
    exported: i64,
    term: std.atomic.Value(i64) = .init(0),
    leave_result: std.atomic.Value(i64) = .init(99),

    fn run(self: *@This()) void {
        if (ex_term_runtime_enter(self.runtime) != 0) return;
        const term = ex_term_import(self.runtime, self.exported);
        self.term.store(term, .release);
        self.leave_result.store(ex_term_runtime_leave(), .release);
    }
};

test "import publishes its term pin before leave and destroy can proceed" {
    const source = createScalarResultFixture();
    const exported = ex_term_export(source.result, source.word);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(source.result));
    const target_runtime = ex_term_runtime_create();

    const gate = &LifecycleTestState.gate;
    gate.arm(.import_validated, "import-pin-before-destroy", 0x60_07);
    defer gate.disarm();

    var import_probe = ImportLeaveProbe{ .runtime = target_runtime, .exported = exported };
    const import_thread = try std.Thread.spawn(.{}, ImportLeaveProbe.run, .{&import_probe});
    var import_joined = false;
    defer {
        gate.release();
        if (!import_joined) import_thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    try std.testing.expectEqual(LifecyclePhase.executing, gate.snapshot.phase);
    try std.testing.expectEqual(@as(u32, 1), gate.snapshot.participants);

    var destroy_probe = LifecycleCallProbe{ .call = .runtime_destroy, .first = target_runtime };
    const destroy_thread = try std.Thread.spawn(.{}, LifecycleCallProbe.run, .{&destroy_probe});
    var destroy_joined = false;
    defer if (!destroy_joined) destroy_thread.join();
    try std.testing.expect(waitLifecycleFlag(&destroy_probe.started, "import-pin-before-destroy", 0x60_07));

    gate.release();
    import_thread.join();
    import_joined = true;
    destroy_thread.join();
    destroy_joined = true;

    const term = import_probe.term.load(.acquire);
    try std.testing.expect(term > 0);
    try std.testing.expectEqual(@as(i64, 0), import_probe.leave_result.load(.acquire));
    try std.testing.expectEqual(@as(i64, -2), destroy_probe.result.load(.acquire));
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_enter(target_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(term));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(target_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(target_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

const ExportedStartGate = struct {
    ready: std.atomic.Value(u32) = .init(0),
    released: std.atomic.Value(bool) = .init(false),
};

const ExportedCall = enum { clone, destroy, length, first_byte };

const ExportedCallProbe = struct {
    gate: *ExportedStartGate,
    call: ExportedCall,
    handle: i64,
    result: i64 = -99,

    fn run(self: *@This()) void {
        _ = self.gate.ready.fetchAdd(1, .acq_rel);
        while (!self.gate.released.load(.acquire)) std.Thread.yield() catch {};
        self.result = switch (self.call) {
            .clone => ex_term_exported_clone(self.handle),
            .destroy => ex_term_exported_destroy(self.handle),
            .length => ex_term_exported_length(self.handle),
            .first_byte => ex_term_exported_get(self.handle, 0),
        };
    }
};

test "exported clone inspection and destroy serialize without stale reads" {
    const source = createScalarResultFixture();
    const exported = ex_term_export(source.result, source.word);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(source.result));
    try std.testing.expectEqual(exported, ex_term_exported_clone(exported));
    try std.testing.expectEqual(exported, ex_term_exported_clone(exported));
    try std.testing.expectEqual(exported, ex_term_exported_clone(exported));

    var start = ExportedStartGate{};
    var probes = [_]ExportedCallProbe{
        .{ .gate = &start, .call = .clone, .handle = exported },
        .{ .gate = &start, .call = .destroy, .handle = exported },
        .{ .gate = &start, .call = .length, .handle = exported },
        .{ .gate = &start, .call = .first_byte, .handle = exported },
    };
    var threads: [probes.len]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, ExportedCallProbe.run, .{&probes[index]});
    }
    while (start.ready.load(.acquire) != probes.len) std.Thread.yield() catch {};
    start.released.store(true, .release);
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(exported, probes[0].result);
    try std.testing.expectEqual(@as(i64, 0), probes[1].result);
    try std.testing.expect(probes[2].result > exported_magic.len);
    try std.testing.expectEqual(@as(i64, 'B'), probes[3].result);
    for (0..4) |_| try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
    try std.testing.expectEqual(@as(i64, -1), ex_term_exported_length(exported));
}

fn createWideResultFixture() ScalarResultFixture {
    const runtime_handle = ex_term_runtime_create();
    std.debug.assert(runtime_handle > 0);
    std.debug.assert(ex_term_runtime_enter(runtime_handle) == 0);
    std.debug.assert(ex_term_process_table_reset(default_process_cap) == 1);
    const element_count = 4096;
    const words = alloc_words(element_count + 1).?;
    words[0] = element_count;
    for (words[1 .. element_count + 1], 0..) |*element, index| {
        element.* = @as(i64, @intCast(index)) << 3;
    }
    const word = word_from_ptr(words, tag_tuple);
    const result = ex_term_result_create(runtime_handle, word);
    std.debug.assert(result > 0);
    std.debug.assert(ex_term_runtime_leave() == 0);
    return .{ .runtime = runtime_handle, .result = result, .word = word };
}

fn runtimeForResult(handle: i64) *Runtime {
    result_lock.lock();
    defer result_lock.unlock();
    return result_slot_locked(handle).?.runtime.?;
}

fn runtimeForTerm(handle: i64) *Runtime {
    term_lock.lock();
    defer term_lock.unlock();
    return term_slot_locked(handle).?.runtime.?;
}

fn runtimeForHandle(handle: i64) *Runtime {
    runtime_lock.lock();
    defer runtime_lock.unlock();
    return runtime_slot_locked(handle).?.runtime.?;
}

const IndependentRuntimeProbe = struct {
    done: std.atomic.Value(bool) = .init(false),
    succeeded: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        var ok = true;
        const handle = ex_term_runtime_create();
        ok = ok and handle > 0;
        ok = ok and ex_term_runtime_enter(handle) == 0;
        ok = ok and ex_term_process_table_reset(2) == 1;
        const result = ex_term_result_create(handle, 80);
        ok = ok and result > 0;
        ok = ok and ex_term_runtime_leave() == 0;
        const exported = ex_term_export(result, 80);
        ok = ok and exported > 0;
        ok = ok and ex_term_exported_length(exported) > exported_magic.len;
        ok = ok and ex_term_exported_destroy(exported) == 0;
        ok = ok and ex_term_result_destroy(result) == 0;
        self.succeeded.store(ok, .release);
        self.done.store(true, .release);
    }
};

fn expectIndependentRuntimeProgress(case_name: []const u8, seed: u64) !void {
    var probe = IndependentRuntimeProbe{};
    const thread = try std.Thread.spawn(.{}, IndependentRuntimeProbe.run, .{&probe});
    var joined = false;
    defer if (!joined) thread.join();
    try std.testing.expect(waitLifecycleFlag(&probe.done, case_name, seed));
    thread.join();
    joined = true;
    try std.testing.expect(probe.succeeded.load(.acquire));
}

test "independent runtime progresses while result graph export is paused" {
    const fixture = createWideResultFixture();
    const gate = &CrossRuntimeTestState.gate;
    gate.arm(.export_traversal, runtimeForResult(fixture.result), "result-export-progress", 0x62_01);
    defer gate.disarm();

    var export_probe = LifecycleCallProbe{
        .call = .result_export,
        .first = fixture.result,
        .second = fixture.word,
    };
    const export_thread = try std.Thread.spawn(.{}, LifecycleCallProbe.run, .{&export_probe});
    var export_joined = false;
    defer {
        gate.release();
        if (!export_joined) export_thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    try expectIndependentRuntimeProgress("result-export-progress", 0x62_01);
    try std.testing.expect(!export_probe.done.load(.acquire));

    gate.release();
    export_thread.join();
    export_joined = true;
    const exported = export_probe.result.load(.acquire);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(fixture.result));
}

test "independent runtime progresses while term handle export is paused" {
    const source = createWideResultFixture();
    const exported = ex_term_export(source.result, source.word);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(source.result));
    const target = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(target));
    const term = ex_term_import(target, exported);
    try std.testing.expect(term > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    const gate = &CrossRuntimeTestState.gate;
    gate.arm(.export_traversal, runtimeForTerm(term), "term-export-progress", 0x62_02);
    defer gate.disarm();
    var export_probe = LifecycleCallProbe{ .call = .term_export, .first = term };
    const export_thread = try std.Thread.spawn(.{}, LifecycleCallProbe.run, .{&export_probe});
    var export_joined = false;
    defer {
        gate.release();
        if (!export_joined) export_thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    try expectIndependentRuntimeProgress("term-export-progress", 0x62_02);
    try std.testing.expect(!export_probe.done.load(.acquire));

    gate.release();
    export_thread.join();
    export_joined = true;
    const copy = export_probe.result.load(.acquire);
    try std.testing.expect(copy > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(term));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(target));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(copy));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

const CrossRuntimeImportProbe = struct {
    runtime_handle: i64,
    exported: i64,
    term: std.atomic.Value(i64) = .init(0),
    leave_result: std.atomic.Value(i64) = .init(99),
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *@This()) void {
        if (ex_term_runtime_enter(self.runtime_handle) == 0) {
            self.term.store(ex_term_import(self.runtime_handle, self.exported), .release);
            self.leave_result.store(ex_term_runtime_leave(), .release);
        }
        self.done.store(true, .release);
    }
};

test "independent runtime progresses while graph import owns another runtime gate" {
    const source = createWideResultFixture();
    const exported = ex_term_export(source.result, source.word);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(source.result));
    const target = ex_term_runtime_create();

    const gate = &CrossRuntimeTestState.gate;
    gate.arm(.import_decode, runtimeForHandle(target), "import-progress", 0x62_03);
    defer gate.disarm();
    var import_probe = CrossRuntimeImportProbe{ .runtime_handle = target, .exported = exported };
    const import_thread = try std.Thread.spawn(.{}, CrossRuntimeImportProbe.run, .{&import_probe});
    var import_joined = false;
    defer {
        gate.release();
        if (!import_joined) import_thread.join();
    }

    try std.testing.expect(gate.waitArrived());
    try expectIndependentRuntimeProgress("import-progress", 0x62_03);
    try std.testing.expect(!import_probe.done.load(.acquire));

    gate.release();
    import_thread.join();
    import_joined = true;
    const term = import_probe.term.load(.acquire);
    try std.testing.expect(term > 0);
    try std.testing.expectEqual(@as(i64, 0), import_probe.leave_result.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(term));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(target));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

test "runtime lifecycle admits one owner and tracks joined workers" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    const instance = active_runtime.?;
    const first_epoch = instance.execution_epoch;

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    try std.testing.expectEqual(first_epoch, instance.execution_epoch);
    try std.testing.expectEqual(@as(u32, 1), instance.execution_participants);
    try std.testing.expect(!worker_join(instance, handle, first_epoch));
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_create(handle, 7));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    try std.testing.expectEqual(@as(i64, -1), ex_term_process_table_reset(default_process_cap));

    var competing = CompetingEnterProbe{ .handle = handle };
    const competitor = try std.Thread.spawn(.{}, CompetingEnterProbe.run, .{&competing});
    competitor.join();
    try std.testing.expectEqual(@as(i64, -2), competing.result.load(.acquire));

    var worker = WorkerLeaseProbe{
        .instance = instance,
        .handle = handle,
        .epoch = first_epoch,
    };
    const thread = try std.Thread.spawn(.{}, WorkerLeaseProbe.run, .{&worker});
    while (!worker.ready.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(u32, 2), instance.execution_participants);
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_leave());
    worker.release.store(true, .release);
    thread.join();
    try std.testing.expect(worker.left.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), instance.execution_participants);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    try std.testing.expectEqual(first_epoch + 1, instance.execution_epoch);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

const WorkerRoleBoundaryProbe = struct {
    instance: *Runtime,
    handle: i64,
    stale_epoch: u64,
    current_epoch: u64,
    stale_joined: bool = true,
    foreign_joined: bool = true,
    current_joined: bool = false,
    enter_result: i64 = 99,
    reset_result: i64 = 99,
    result_create_result: i64 = 99,
    public_leave_result: i64 = 99,
    first_worker_leave: bool = false,
    repeated_worker_leave: bool = true,

    fn run(self: *@This()) void {
        self.stale_joined = worker_join(self.instance, self.handle, self.stale_epoch);
        self.foreign_joined = worker_join(self.instance, self.handle + 1, self.current_epoch);
        self.current_joined = worker_join(self.instance, self.handle, self.current_epoch);
        if (!self.current_joined) return;

        self.enter_result = ex_term_runtime_enter(self.handle);
        self.reset_result = ex_term_process_table_reset(default_process_cap);
        self.result_create_result = ex_term_result_create(self.handle, 7);
        self.public_leave_result = ex_term_runtime_leave();
        self.first_worker_leave = worker_leave();
        self.repeated_worker_leave = worker_leave();
    }
};

test "worker tokens reject stale foreign and repeated lifecycle operations" {
    try std.testing.expectEqual(@as(i64, -1), ex_term_runtime_leave());

    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    const instance = active_runtime.?;
    const stale_epoch = instance.execution_epoch;
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    const current_epoch = instance.execution_epoch;
    try std.testing.expect(current_epoch != stale_epoch);

    var probe = WorkerRoleBoundaryProbe{
        .instance = instance,
        .handle = handle,
        .stale_epoch = stale_epoch,
        .current_epoch = current_epoch,
    };
    const thread = try std.Thread.spawn(.{}, WorkerRoleBoundaryProbe.run, .{&probe});
    thread.join();

    try std.testing.expect(!probe.stale_joined);
    try std.testing.expect(!probe.foreign_joined);
    try std.testing.expect(probe.current_joined);
    try std.testing.expectEqual(@as(i64, -2), probe.enter_result);
    try std.testing.expectEqual(@as(i64, -1), probe.reset_result);
    try std.testing.expectEqual(@as(i64, -1), probe.result_create_result);
    try std.testing.expectEqual(@as(i64, -1), probe.public_leave_result);
    try std.testing.expect(probe.first_worker_leave);
    try std.testing.expect(!probe.repeated_worker_leave);
    try std.testing.expectEqual(@as(u32, 1), instance.execution_participants);

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

test "execution epoch reaches its maximum without wrapping" {
    const handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    const instance = active_runtime.?;
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    instance.lifecycle_lock.lock();
    instance.execution_epoch = std.math.maxInt(u64) - 1;
    instance.lifecycle_lock.unlock();

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    try std.testing.expectEqual(std.math.maxInt(u64), instance.execution_epoch);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_enter(handle));
    try std.testing.expectEqual(std.math.maxInt(u64), instance.execution_epoch);
    try std.testing.expectEqual(LifecyclePhase.idle, instance.lifecycle_phase);
    try std.testing.expectEqual(@as(i64, 0), instance.execution_handle);
    try std.testing.expectEqual(@as(u32, 0), instance.execution_participants);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

test "host result handles retain terms and reject stale generations" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const tuple = tuple3(8, 16, 24);
    const handle = ex_term_result_create(runtime_handle, tuple);
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    try std.testing.expectEqual(@as(i64, tag_tuple), ex_term_result_root_kind(handle));
    try std.testing.expectEqual(tuple, ex_term_result_root_word(handle));
    try std.testing.expectEqual(@as(i64, 3), ex_term_result_term_length(handle, tuple));
    try std.testing.expectEqual(@as(i64, 16), ex_term_result_term_get(handle, tuple, 1));
    try std.testing.expectEqual(@as(i64, tag_int), ex_term_result_term_kind(handle, 16));
    try std.testing.expect(ex_term_result_arena_capacity_bytes(handle) > 0);
    try std.testing.expect(ex_term_result_arena_chunks(handle) > 0);
    try std.testing.expect(ex_term_result_arena_high_water(handle) > 0);
    try std.testing.expectEqual(
        @as(i64, @intCast(arena_hard_limit_bytes)),
        ex_term_result_arena_limit(handle),
    );
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_oom(handle));

    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_root_kind(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_arena_high_water(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_destroy(handle));
}

test "host result roots preserve untagged scalar compatibility" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const handle = ex_term_result_create(runtime_handle, 3);
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_root_kind(handle));
    try std.testing.expectEqual(@as(i64, 3), ex_term_result_root_word(handle));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(handle));
}

test "host results reject runtime-local pid and reference roots" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const pid_result = ex_term_result_create(runtime_handle, pid_of(0, 1));
    try std.testing.expect(pid_result > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_root_kind(pid_result));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(pid_result));

    const ref_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(ref_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const ref_result = ex_term_result_create(ref_runtime, runtime_local_word(runtime_local_ref, 1));
    try std.testing.expect(ref_result > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_root_kind(ref_result));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(ref_result));
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

test "arena OOM is distinct from nil and exposes usage metrics" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    try std.testing.expect(alloc_words(arena_hard_limit_words + 1) == null);
    try std.testing.expectEqual(@as(i64, 1), ex_term_runtime_oom(runtime_handle));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_arena_chunks(runtime_handle));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_arena_bytes(runtime_handle));
    try std.testing.expectEqual(@as(i64, -2), ex_term_result_create(runtime_handle, nil_word));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(runtime_handle));
}

test "runtime arena quota fails closed and survives execution reset" {
    const runtime_handle = ex_term_runtime_create();
    const quota_bytes: i64 = 16;

    try std.testing.expectEqual(@as(i64, -3), ex_term_runtime_set_arena_limit(runtime_handle, -1));
    try std.testing.expectEqual(
        @as(i64, -3),
        ex_term_runtime_set_arena_limit(runtime_handle, @as(i64, @intCast(arena_hard_limit_bytes)) + 1),
    );
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_set_arena_limit(runtime_handle, quota_bytes));
    try std.testing.expectEqual(quota_bytes, ex_term_runtime_arena_limit(runtime_handle));

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_set_arena_limit(runtime_handle, 8));
    try std.testing.expect(alloc_words(2) != null);
    try std.testing.expect(alloc_words(1) == null);
    try std.testing.expectEqual(quota_bytes, ex_term_runtime_arena_high_water(runtime_handle));
    try std.testing.expectEqual(@as(i64, 1), ex_term_runtime_oom(runtime_handle));

    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_arena_high_water(runtime_handle));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_oom(runtime_handle));
    try std.testing.expectEqual(quota_bytes, ex_term_runtime_arena_limit(runtime_handle));
    try std.testing.expect(alloc_words(2) != null);

    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(runtime_handle));
}

test "runtime destroy rejects an outstanding result handle" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const handle = ex_term_result_create(runtime_handle, 7);
    try std.testing.expect(handle > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_destroy(runtime_handle));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(handle));
}

test "explicit runtime handles reject stale generations and entered destroy" {
    const handle = ex_term_runtime_create();
    try std.testing.expect(handle != 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(handle));
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_destroy(handle));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_runtime_enter(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_runtime_destroy(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_runtime_arena_bytes(handle));
}

test "a result runtime has one owner and waits for every worker to leave" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const handle = ex_term_result_create(runtime_handle, 7);
    try std.testing.expect(handle > 0);
    try std.testing.expectEqual(@as(i64, -3), ex_term_result_create(runtime_handle, 8));
    try std.testing.expectEqual(@as(i64, -2), ex_term_result_destroy(handle));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(handle));
    try std.testing.expectEqual(@as(i64, -1), ex_term_runtime_enter(runtime_handle));
}

test "portable export survives source destroy and imports into an explicit target" {
    const source_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(source_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));

    const binary_words = alloc_binary(3).?;
    const binary = word_from_ptr(binary_words, tag_binary);
    @memcpy(binary_bytes(binary)[0..3], "abc");
    const cons_words = alloc_words(2).?;
    cons_words[0] = 16;
    cons_words[1] = 25; // atom id 3
    const improper = word_from_ptr(cons_words, tag_list);
    const map_words = alloc_words(3).?;
    map_words[0] = 1;
    map_words[1] = 33; // atom id 4
    map_words[2] = binary;
    const map = word_from_ptr(map_words, tag_map);
    const root = tuple3(improper, map, nil_word);

    const result = ex_term_result_create(source_runtime, root);
    try std.testing.expectEqual(@as(i64, -5), ex_term_export(result, root));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const exported = ex_term_export(result, root);
    try std.testing.expect(exported > 0);
    try std.testing.expect(ex_term_exported_length(exported) > exported_magic.len);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(result));

    const target_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(target_runtime));
    const imported = ex_term_import(target_runtime, exported);
    try std.testing.expect(imported > 0);
    try std.testing.expect(ex_term_handle_root_word(imported) > 0);
    try std.testing.expectEqual(@as(i64, -5), ex_term_handle_export(imported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const round_trip = ex_term_handle_export(imported);
    try std.testing.expect(round_trip > 0);
    const length = ex_term_exported_length(exported);
    try std.testing.expectEqual(length, ex_term_exported_length(round_trip));
    for (0..@intCast(length)) |index| {
        try std.testing.expectEqual(
            ex_term_exported_get(exported, @intCast(index)),
            ex_term_exported_get(round_trip, @intCast(index)),
        );
    }

    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_destroy(target_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(imported));
    try std.testing.expectEqual(@as(i64, -1), ex_term_handle_root_word(imported));
    try std.testing.expectEqual(@as(i64, -1), ex_term_handle_destroy(imported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(target_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(round_trip));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

test "term and result pins preserve one runtime until ordered destruction" {
    const source_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(source_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const source_result = ex_term_result_create(source_runtime, 8);
    try std.testing.expect(source_result > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const exported = ex_term_export(source_result, 8);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(source_result));

    const target_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(target_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const imported = ex_term_import(target_runtime, exported);
    try std.testing.expect(imported > 0);
    term_lock.lock();
    const imported_word = term_slot_locked(imported).?.word;
    term_lock.unlock();
    const target_result = ex_term_result_create(target_runtime, imported_word);
    try std.testing.expect(target_result > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    const result_lease = try begin_result_export(target_result, imported_word);
    try std.testing.expectEqual(@as(i64, -2), ex_term_result_destroy(target_result));
    finish_export(result_lease.runtime);
    try std.testing.expectEqual(@as(i64, -2), ex_term_result_destroy(target_result));
    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(imported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(target_result));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

test "term pins block reset until released and export leases protect snapshots" {
    const source_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(source_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const source_result = ex_term_result_create(source_runtime, 8);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const exported = ex_term_export(source_result, 8);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(source_result));

    const target_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(target_runtime));
    const imported = ex_term_import(target_runtime, exported);
    try std.testing.expect(imported > 0);
    try std.testing.expectEqual(@as(i64, -1), ex_term_process_table_reset(default_process_cap));
    try std.testing.expectEqual(@as(i64, -1), ex_term_result_create(target_runtime, 8));
    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(imported));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(target_runtime));

    const storage_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(storage_runtime));
    const storage_term = ex_term_import(storage_runtime, exported);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const lease = try begin_term_export(storage_term);
    try std.testing.expectEqual(LifecyclePhase.exporting, lease.runtime.lifecycle_phase);
    try std.testing.expectEqual(@as(i64, -2), ex_term_runtime_destroy(storage_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(storage_term));
    const copy = registerExported(lease.runtime, lease.word, lease.root_scalar);
    try std.testing.expect(copy > 0);
    finish_export(lease.runtime);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(storage_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(copy));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

test "portable codec preserves boxed integer bytes across runtime ownership" {
    const decimal = "100000000000000000000000000000000000000000000000000000000000000000000";
    const source_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(source_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const bigint = ex_term_bigint_lit(test_binary_from_string(decimal));
    const result = ex_term_result_create(source_runtime, bigint);
    try std.testing.expect(result > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const exported = ex_term_export(result, bigint);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(result));

    const target_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(target_runtime));
    const imported = ex_term_import(target_runtime, exported);
    try std.testing.expect(imported > 0);
    const imported_word = ex_term_handle_root_word(imported);
    try std.testing.expect(is_bigint(imported_word));
    try std.testing.expectEqual(decimal.len, bigint_len(imported_word));
    try std.testing.expect(std.mem.eql(u8, decimal, bigint_bytes(imported_word)[0..decimal.len]));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    try std.testing.expectEqual(@as(i64, 0), ex_term_handle_destroy(imported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(target_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

test "portable handles reject stale generations and unsupported closures" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const closure_words = alloc_words(2).?;
    closure_words[0] = 7;
    closure_words[1] = 0;
    const closure = word_from_ptr(closure_words, tag_fun);
    const result = ex_term_result_create(runtime_handle, closure);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, -3), ex_term_export(result, closure));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(result));

    const scalar_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(scalar_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const scalar_result = ex_term_result_create(scalar_runtime, 3);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const exported = ex_term_export(scalar_result, 3);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(exported, ex_term_exported_clone(exported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(scalar_result));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
    try std.testing.expect(ex_term_exported_length(exported) > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
    try std.testing.expectEqual(@as(i64, -1), ex_term_exported_length(exported));
    try std.testing.expectEqual(@as(i64, -1), ex_term_exported_destroy(exported));
}

test "portable export deterministically rejects runtime-local values" {
    const pid_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(pid_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const pid_result = ex_term_result_create(pid_runtime, pid_of(0, 1));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, -3), ex_term_export(pid_result, ex_term_result_root_word(pid_result)));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(pid_result));

    const nested_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(nested_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const nested = tuple3(8, runtime_local_word(runtime_local_ref, 1), 16);
    const nested_result = ex_term_result_create(nested_runtime, nested);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, -3), ex_term_export(nested_result, nested));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(nested_result));
}

test "portable import rejects a target runtime that is not explicitly entered" {
    const source_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(source_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const result = ex_term_result_create(source_runtime, 8);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const exported = ex_term_export(result, 8);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(result));

    const target_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, -5), ex_term_import(target_runtime, exported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(target_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));
}

test "portable boundary rejects malformed encodings and foreign arena words" {
    const source_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(source_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const result = ex_term_result_create(source_runtime, 8);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    const exported = ex_term_export(result, 8);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(result));

    exported_lock.lock();
    exported_slot_locked(exported).?.bytes.?[0] = 'X';
    exported_lock.unlock();
    const target_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(target_runtime));
    try std.testing.expectEqual(@as(i64, -4), ex_term_import(target_runtime, exported));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(target_runtime));
    try std.testing.expectEqual(@as(i64, 0), ex_term_exported_destroy(exported));

    const foreign_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(foreign_runtime));
    const foreign_tuple = tuple3(8, 16, 24);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());

    const owner_runtime = ex_term_runtime_create();
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(owner_runtime));
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset(default_process_cap));
    const owner_words = alloc_words(2).?;
    owner_words[0] = 1;
    owner_words[1] = foreign_tuple;
    const owner_tuple = word_from_ptr(owner_words, tag_tuple);
    const owner_result = ex_term_result_create(owner_runtime, owner_tuple);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, -1), ex_term_export(owner_result, owner_tuple));
    try std.testing.expectEqual(@as(i64, 0), ex_term_result_destroy(owner_result));
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(foreign_runtime));
}

const ActorClaimProbe = struct {
    instance: *Runtime,
    handle: i64,
    epoch: u64,
    ready: std.atomic.Value(u32) = .init(0),
    claimed: std.atomic.Value(u32) = .init(0),
    pids: [2]i64 = undefined,

    fn run(self: *@This(), slot: usize) void {
        if (!worker_join(self.instance, self.handle, self.epoch)) return;
        defer _ = worker_leave();
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (self.ready.load(.acquire) != self.pids.len) std.Thread.yield() catch {};

        self.pids[slot] = ex_term_process_claim_next(@intCast(slot + 1));
        _ = self.claimed.fetchAdd(1, .acq_rel);
        while (self.claimed.load(.acquire) != self.pids.len) std.Thread.yield() catch {};

        _ = ex_term_process_release();
    }
};

test "workers claim distinct actors from one runtime" {
    const handle = ex_term_runtime_create();
    _ = ex_term_runtime_enter(handle);
    _ = ex_term_process_table_reset(default_process_cap);
    _ = ex_term_spawn(nil_word);

    const instance = active_runtime.?;
    var probe = ActorClaimProbe{
        .instance = instance,
        .handle = handle,
        .epoch = instance.execution_epoch,
    };
    const first = try std.Thread.spawn(.{}, ActorClaimProbe.run, .{ &probe, 0 });
    const second = try std.Thread.spawn(.{}, ActorClaimProbe.run, .{ &probe, 1 });
    first.join();
    second.join();

    try std.testing.expect(probe.pids[0] != nil_word);
    try std.testing.expect(probe.pids[1] != nil_word);
    try std.testing.expect(probe.pids[0] != probe.pids[1]);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_destroy(handle));
}

const MailboxSendProbe = struct {
    instance: *Runtime,
    handle: i64,
    epoch: u64,
    pid: i64,

    fn run(self: @This(), slot: usize) void {
        if (!worker_join(self.instance, self.handle, self.epoch)) return;
        defer _ = worker_leave();
        for (0..16) |i| {
            const value: i64 = @intCast(slot * 16 + i);
            _ = ex_term_send(self.pid, value << @intCast(tag_shift));
        }
    }
};

test "mailbox accepts concurrent cross-worker sends without loss" {
    const handle = ex_term_runtime_create();
    _ = ex_term_runtime_enter(handle);
    _ = ex_term_process_table_reset(default_process_cap);
    const pid = ex_term_self();

    const instance = active_runtime.?;
    const probe = MailboxSendProbe{
        .instance = instance,
        .handle = handle,
        .epoch = instance.execution_epoch,
        .pid = pid,
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, slot| {
        thread.* = try std.Thread.spawn(.{}, MailboxSendProbe.run, .{ probe, slot });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(i64, 64), ex_term_mailbox_len());
    var seen = [_]bool{false} ** 64;
    for (0..64) |_| {
        const value = word_payload(ex_term_receive());
        try std.testing.expect(value >= 0 and value < seen.len);
        try std.testing.expect(!seen[@intCast(value)]);
        seen[@intCast(value)] = true;
    }
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
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
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
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

fn exception_boundary_dispatch(pid: i64) callconv(.c) i64 {
    if (pid_index(pid) == 0) ex_term_raise(99 << @intCast(tag_shift), 1);
    return pid;
}

test "typed raise unwinds to the innermost try with its kind" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expect(runtime_handle > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(runtime_handle);
    }

    var user_catch: c.jmp_buf = undefined;
    try std.testing.expectEqual(@as(i64, 0), ex_term_try_push(&user_catch));

    if (c.setjmp(&user_catch) == 0) {
        ex_term_raise(99 << @intCast(tag_shift), 1);
        unreachable;
    } else {
        const caught = ex_term_catch_value();
        try std.testing.expectEqual(@as(i64, 1 << @intCast(tag_shift)), ex_term_tuple_get(caught, 0));
        try std.testing.expectEqual(@as(i64, 99 << @intCast(tag_shift)), ex_term_tuple_get(caught, 1));
    }

    try std.testing.expectEqual(@as(i64, 0), ex_term_try_pop());
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
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
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
    try std.testing.expect(is_runtime_ref(reference));

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
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_leave());
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
    try std.testing.expectEqual(@as(i64, 0), ex_term_is_atom(grown));
    try std.testing.expect(is_pid(grown));
    try std.testing.expectEqual(@as(i64, 4), ex_term_processes_runnable());
}

fn protectedRaise(context: i64) callconv(.c) i64 {
    ex_term_raise(context, 6);
}

fn protectedIdentity(context: i64) callconv(.c) i64 {
    return context;
}

test "protected host calls close normal and raised control paths" {
    var caught: i64 = -1;
    var kind: i64 = -1;

    try std.testing.expectEqual(@as(i64, 42), ex_term_protected_call(&protectedIdentity, 42, &caught, &kind));
    try std.testing.expectEqual(@as(i64, 0), caught);
    try std.testing.expectEqual(@as(i64, 0), kind);

    try std.testing.expectEqual(@as(i64, 99), ex_term_protected_call(&protectedRaise, 99, &caught, &kind));
    try std.testing.expectEqual(@as(i64, 1), caught);
    try std.testing.expectEqual(@as(i64, 6), kind);
}

test "term ABI throw unwinds to the innermost try" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expect(runtime_handle > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(runtime_handle);
    }

    var buf: c.jmp_buf = undefined;
    try std.testing.expectEqual(@as(i64, 0), ex_term_try_push(&buf));

    if (c.setjmp(&buf) == 0) {
        // Normal path: throw longjmps back to the setjmp above.
        ex_term_throw(42 << @intCast(tag_shift));
        unreachable;
    } else {
        const caught = ex_term_catch_value();
        try std.testing.expectEqual(@as(i64, 0), ex_term_tuple_get(caught, 0));
        try std.testing.expectEqual(@as(i64, 42 << @intCast(tag_shift)), ex_term_tuple_get(caught, 1));
    }

    try std.testing.expectEqual(@as(i64, 0), ex_term_try_pop());

    // jmp_buf size is positive and matches the C ABI
    try std.testing.expect(ex_term_jmp_buf_size() > 0);
}

test "host byte copies own their binary storage" {
    const runtime_handle = ex_term_runtime_create();
    try std.testing.expect(runtime_handle > 0);
    try std.testing.expectEqual(@as(i64, 0), ex_term_runtime_enter(runtime_handle));
    defer {
        _ = ex_term_runtime_leave();
        _ = ex_term_runtime_destroy(runtime_handle);
    }

    var source = [_]u8{ 0x42, 0x61, 0x74, 0x61, 0x74, 0x61 };
    const binary = ex_term_binary_from_bytes(&source, source.len);
    source[0] = 0;
    try std.testing.expectEqual(@as(i64, 6), ex_term_binary_length(binary));

    var destination = [_]u8{0} ** 6;
    try std.testing.expectEqual(@as(i64, 6), ex_term_binary_copy(binary, &destination, destination.len));
    try std.testing.expectEqualSlices(u8, "Batata", &destination);
    try std.testing.expectEqual(@as(i64, -1), ex_term_binary_copy(binary, &destination, 5));
    try std.testing.expectEqual(@as(i64, -1), ex_term_binary_copy(nil_word, &destination, destination.len));
}

fn ex_term_is_nil_word(word: i64) i64 {
    return if (word == nil_word) 1 else 0;
}
