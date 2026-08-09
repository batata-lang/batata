//! Zig term runtime for the `ex` dialect.
//!
//! Implements the declaration-first ABI in `native/ABI.md`. All exported
//! symbols are C ABI functions over 64-bit tagged words; Beaver's ex
//! conversion plan emits calls to exactly these symbols.

const std = @import("std");
const c = @cImport({
    @cInclude("setjmp.h");
    @cInclude("stdio.h");
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

// Actor scheduling model (#35): a single process with a FIFO mailbox and a
// reduction clock. `Clock.used` is charged by `ex.term.clock_tick` before
// effectful steps / loop back-edges; when it exceeds `budget` the compiled
// code yields. `epoch` is a continuation-generation counter: message arrival
// or a scheduler round bumps it, invalidating stale resume tokens.
const mailbox_cap: usize = 64;

const Clock = struct {
    budget: i64,
    used: i64,
    epoch: i64,
};

const Mailbox = struct {
    queue: [mailbox_cap]i64 = undefined,
    head: usize = 0,
    len: usize = 0,

    fn push(self: *Mailbox, msg: i64) bool {
        if (self.len >= mailbox_cap) return false;
        const index = (self.head + self.len) % mailbox_cap;
        self.queue[index] = msg;
        self.len += 1;
        return true;
    }

    fn pop(self: *Mailbox) ?i64 {
        if (self.len == 0) return null;
        const msg = self.queue[self.head];
        self.head = (self.head + 1) % mailbox_cap;
        self.len -= 1;
        return msg;
    }

    fn clear(self: *Mailbox) void {
        self.head = 0;
        self.len = 0;
    }
};

const ProcessStatus = enum(u8) { runnable, done };

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
    pid: i64,
    mailbox: Mailbox = .{},
    clock: Clock,
    // Closure word of the spawned entry; 0 for the initial process, whose
    // entry is the compiled `__batata_entry` function.
    entry: i64 = 0,
    status: ProcessStatus = .runnable,
    result: i64 = nil_word,
    cont: Continuation = .{},
};

// Process table (#35 slice 4/5): a fixed-capacity set of actors, each with
// its own FIFO mailbox, reduction clock, entry, status and continuation.
// `current` is the executing process; spawn allocates a new entry and returns
// its pid; schedule_next round-robins runnable processes for the driver.
const process_cap: usize = 8;
var processes: [process_cap]Process = undefined;
var process_count: usize = 1;
var current_process: usize = 0;
var processes_initialized = false;

fn init_processes() void {
    processes[0] = .{
        .pid = (1 << @intCast(tag_shift)) | @as(i64, @intCast(tag_atom)),
        .clock = .{ .budget = 0, .used = 0, .epoch = 0 },
    };
    process_count = 1;
    current_process = 0;
}

fn current_proc() *Process {
    if (!processes_initialized) {
        init_processes();
        processes_initialized = true;
    }
    return &processes[current_process];
}

fn pid_of(index: usize) i64 {
    return (@as(i64, @intCast(index + 1)) << @intCast(tag_shift)) |
        @as(i64, @intCast(tag_atom));
}

/// Resets the process table to a single fresh initial process. The scheduler
/// driver calls this at program start so each run observes a clean actor
/// table (processes/mailboxes do not leak across `Batata.execute` calls).
pub export fn ex_term_process_table_reset() i64 {
    init_processes();
    processes_initialized = true;
    return 1;
}

// Preemptive yield accounting (#35 slice 3): the compiled loop driver
// charges slices of the reduction budget; each slice boundary is a yield
// point. The epoch is checked across slices (a message arrival or scheduler
// round bumps it, invalidating the continuation).
var yield_count: i64 = 0;

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
    return current_proc().pid;
}

/// Enqueues a message to the process's mailbox, routing by pid; returns the
/// message itself, or nil when the pid is invalid or the mailbox is full.
/// Message delivery does not bump the recipient's epoch in this slice: a
/// plain FIFO receive must observe the message on resume.
pub export fn ex_term_send(pid: i64, msg: i64) i64 {
    _ = current_proc();
    if (word_tag(pid) != tag_atom) return nil_word;
    const pid_id: usize = @intCast(word_payload(pid));
    if (pid_id == 0 or pid_id > @as(usize, @intCast(process_count))) return nil_word;
    if (!processes[pid_id - 1].mailbox.push(msg)) return nil_word;
    // Message arrival invalidates a pending selective-receive continuation:
    // the scan restarts and observes the new message (epoch invalidation
    // wiring, #35 slice 6). Loop continuations are unaffected.
    const target = &processes[pid_id - 1];
    if (target.cont.active and target.cont.receive) {
        target.clock.epoch += 1;
    }
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

/// Number of messages in the current process's mailbox.
pub export fn ex_term_mailbox_len() i64 {
    return @intCast(current_proc().mailbox.len);
}

/// The message at `cursor` (0-based from the mailbox head) without removing
/// it; nil when out of range.
pub export fn ex_term_mailbox_peek(cursor: i64) i64 {
    const proc = current_proc();
    if (cursor < 0 or cursor >= @as(i64, @intCast(proc.mailbox.len))) return nil_word;
    const index = (proc.mailbox.head + @as(usize, @intCast(cursor))) % mailbox_cap;
    return proc.mailbox.queue[index];
}

/// Removes the message at `cursor`, shifting later messages forward; returns
/// 1, or nil when out of range.
pub export fn ex_term_mailbox_remove(cursor: i64) i64 {
    const proc = current_proc();
    if (cursor < 0 or cursor >= @as(i64, @intCast(proc.mailbox.len))) return nil_word;
    var i: usize = @intCast(cursor);
    while (i + 1 < proc.mailbox.len) : (i += 1) {
        const to = (proc.mailbox.head + i) % mailbox_cap;
        const from = (proc.mailbox.head + i + 1) % mailbox_cap;
        proc.mailbox.queue[to] = proc.mailbox.queue[from];
    }
    proc.mailbox.len -= 1;
    return 1;
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
/// returns its pid (atom word with id = process index + 1), or nil when the
/// table is full.
pub export fn ex_term_spawn(fun: i64) i64 {
    if (process_count >= process_cap) return nil_word;
    const index = process_count;
    processes[index] = .{
        .pid = pid_of(index),
        .clock = .{ .budget = 0, .used = 0, .epoch = 0 },
        .entry = fun,
    };
    process_count += 1;
    return processes[index].pid;
}

/// Saves the current process's cursor-loop continuation (list, acc, cursor)
/// at the current epoch. Returns 1.
pub export fn ex_term_cont_save(arg: i64, acc: i64, cursor: i64) i64 {
    const proc = current_proc();
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
    return if (proc.cont.active and proc.cont.epoch == proc.clock.epoch) 1 else 0;
}

/// 1 when the current process has any saved continuation (valid or stale).
/// The entry's mailbox reset is gated on this: a resume — even one whose
/// continuation was invalidated by a message arrival — must keep the messages
/// that arrived while the process was suspended.
pub export fn ex_term_cont_active() i64 {
    return if (current_proc().cont.active) 1 else 0;
}

/// Clears the current process's saved continuation.
pub export fn ex_term_cont_clear() i64 {
    current_proc().cont.active = false;
    return 0;
}

/// Saved loop state (arg/acc/cursor) of the current process's continuation;
/// nil when none is pending.
pub export fn ex_term_cont_load_arg() i64 {
    const proc = current_proc();
    return if (proc.cont.active) proc.cont.arg else nil_word;
}

pub export fn ex_term_cont_load_acc() i64 {
    const proc = current_proc();
    return if (proc.cont.active) proc.cont.acc else nil_word;
}

pub export fn ex_term_cont_load_cursor() i64 {
    const proc = current_proc();
    return if (proc.cont.active) proc.cont.cursor else nil_word;
}

/// Advances to the next runnable process (round-robin from the current one)
/// and returns its pid. Stays on the current process when it is the only
/// runnable one.
pub export fn ex_term_schedule_next() i64 {
    if (process_count <= 1) return processes[0].pid;
    var i: usize = 1;
    while (i <= process_count) : (i += 1) {
        const index = (current_process + i) % process_count;
        if (processes[index].status == .runnable) {
            current_process = index;
            return processes[index].pid;
        }
    }
    return processes[current_process].pid;
}

/// Closure word of the current process's entry; 0 for the initial process
/// (the compiled `__batata_entry`).
pub export fn ex_term_current_entry() i64 {
    return current_proc().entry;
}

/// Marks the current process done and stores its result.
pub export fn ex_term_process_done(result: i64) i64 {
    const proc = current_proc();
    proc.status = .done;
    proc.result = result;
    proc.cont.active = false;
    return result;
}

/// Number of runnable processes (the scheduler driver loops while > 0).
pub export fn ex_term_processes_runnable() i64 {
    var count: i64 = 0;
    for (0..process_count) |i| {
        if (processes[i].status == .runnable) count += 1;
    }
    return count;
}

/// Result of a completed process; nil when the process is unknown or still
/// runnable.
pub export fn ex_term_process_result(pid: i64) i64 {
    if (word_tag(pid) != tag_atom) return nil_word;
    const pid_id: usize = @intCast(word_payload(pid));
    if (pid_id == 0 or pid_id > @as(usize, @intCast(process_count))) return nil_word;
    const proc = processes[pid_id - 1];
    return if (proc.status == .done) proc.result else nil_word;
}

/// Sets the reduction budget and resets the used counter (epoch untouched).
pub export fn ex_term_clock_init(budget: i64) i64 {
    current_proc().clock.budget = budget;
    current_proc().clock.used = 0;
    return budget;
}

/// Charges `cost` reductions; returns 1 when the budget is exhausted (the
/// caller should yield), else 0. Negative cost is clamped to zero.
pub export fn ex_term_clock_tick(cost: i64) i64 {
    if (cost > 0) current_proc().clock.used += cost;
    return if (current_proc().clock.used >= current_proc().clock.budget and current_proc().clock.budget > 0) 1 else 0;
}

/// Remaining reduction budget (clamped to >= 0); -1 when no budget is set.
pub export fn ex_term_clock_budget_left() i64 {
    if (current_proc().clock.budget <= 0) return -1;
    const left = current_proc().clock.budget - current_proc().clock.used;
    return if (left < 0) 0 else left;
}

/// Current continuation-generation counter.
pub export fn ex_term_clock_epoch() i64 {
    return current_proc().clock.epoch;
}

/// Bumps the epoch (message arrival / scheduler round); returns the new value.
pub export fn ex_term_clock_bump_epoch() i64 {
    current_proc().clock.epoch += 1;
    const result = current_proc().clock.epoch;
    return result;
}

/// Number of preemptive yields so far (slice boundaries in the loop driver).
pub export fn ex_term_yield_count() i64 {
    return yield_count;
}

/// Records one yield at a slice boundary and bumps the yield counter.
pub export fn ex_term_yield_mark() i64 {
    yield_count += 1;
    return yield_count;
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

fn read_file_words(path_word: i64) ?[*]i64 {
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
    const words = alloc_words(file_len + 1) orelse return null;
    words[0] = @intCast(file_len);
    for (0..file_len) |i| {
        const ch = c.fgetc(file);
        if (ch == c.EOF) return null;
        words[i + 1] = ch;
    }
    return words;
}

/// Reads a file into a binary term; nil for missing files, non-binary paths,
/// or oversized content.
pub export fn ex_term_file_read(path_word: i64) i64 {
    const words = read_file_words(path_word) orelse return nil_word;
    return word_from_ptr(words, tag_binary);
}

/// Reads a file and splits it into a list of line binaries (without trailing
/// newlines); nil on read failure.
pub export fn ex_term_file_read_lines(path_word: i64) i64 {
    const words = read_file_words(path_word) orelse return nil_word;
    const len: usize = @intCast(words[0]);
    var result = nil_word;
    var line_start: usize = len;
    var i: usize = len;
    while (i > 0) {
        i -= 1;
        if (words[i + 1] == '\n') {
            // 行是 [i+1, line_start)
            const line_len = line_start - (i + 1);
            const line = alloc_words(line_len + 1) orelse return nil_word;
            line[0] = @intCast(line_len);
            var j: usize = 0;
            while (j < line_len) : (j += 1) {
                line[j + 1] = words[i + 1 + j];
            }
            result = ex_term_list_cons(word_from_ptr(line, tag_binary), result);
            line_start = i;
        }
    }
    // 剩余行 [0, line_start)（无换行结尾或首行）
    if (line_start > 0) {
        const line_len = line_start;
        const line = alloc_words(line_len + 1) orelse return nil_word;
        line[0] = @intCast(line_len);
        var j: usize = 0;
        while (j < line_len) : (j += 1) {
            line[j + 1] = words[j];
        }
        result = ex_term_list_cons(word_from_ptr(line, tag_binary), result);
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
    @export(&ex_term_nil, .{ .name = "ex.term.nil" });
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
    @export(&ex_term_current_entry, .{ .name = "ex.term.current_entry" });
    @export(&ex_term_process_done, .{ .name = "ex.term.process_done" });
    @export(&ex_term_processes_runnable, .{ .name = "ex.term.processes_runnable" });
    @export(&ex_term_process_result, .{ .name = "ex.term.process_result" });
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
    try std.testing.expectEqual(@as(i64, 1), ex_term_process_table_reset());
    try std.testing.expectEqual(@as(i64, 1), ex_term_processes_runnable());
    try std.testing.expectEqual(@as(i64, 0), ex_term_current_entry());
    const pid4 = ex_term_spawn(fun);
    try std.testing.expectEqual(@as(i64, 2), ex_term_processes_runnable());
    try std.testing.expectEqual(pid4, ex_term_schedule_next());
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
