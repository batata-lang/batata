const std = @import("std");
const runtime = @import("runtime");
const c = @cImport({
    @cInclude("stdlib.h");
});

const int_shift = 3;
const nil_word: i64 = 1;
const max_senders = 16;
const max_ring_actors = 64;
const max_children = 8;

fn tagged(value: i64) i64 {
    return value << int_shift;
}

fn payload(word: i64) i64 {
    return @divTrunc(word, @as(i64, 1) << int_shift);
}

const SoakConfig = struct {
    seed: u64,
    scale: usize,

    fn load() SoakConfig {
        return .{
            .seed = parseEnvInt(u64, "BATATA_SOAK_SEED", 0x61_01),
            .scale = @max(parseEnvInt(usize, "BATATA_SOAK_SCALE", 1), 1),
        };
    }
};

fn parseEnvInt(comptime T: type, name: []const u8, default: T) T {
    var buffer: [64]u8 = undefined;
    if (name.len + 1 > buffer.len) return default;
    @memcpy(buffer[0..name.len], name);
    buffer[name.len] = 0;
    const value = c.getenv(@ptrCast(&buffer)) orelse return default;
    return std.fmt.parseInt(T, std.mem.span(value), 0) catch default;
}

const CaseContext = struct {
    name: []const u8,
    seed: u64,
    workers: i64,
    process_cap: i64,
    scale: usize,

    fn progress(self: CaseContext, handle: i64, phase: []const u8) void {
        const snapshot = runtime.runtimeSoakSnapshot(handle) orelse return;
        std.debug.print(
            "soak progress: workload={s} seed={d} workers={d} process_cap={d} scale={d} step={s} " ++
                "processes={d}/{d} runnable={d} waiting={d} owned={d} mailbox={d} " ++
                "participants={d} arena_chunks={d} arena_high_water={d} oom={}\n",
            .{
                self.name,
                self.seed,
                self.workers,
                self.process_cap,
                self.scale,
                phase,
                snapshot.process_count,
                snapshot.process_capacity,
                snapshot.runnable,
                snapshot.waiting,
                snapshot.owned,
                snapshot.mailbox_messages,
                snapshot.execution_participants,
                snapshot.arena_chunks,
                snapshot.arena_high_water,
                snapshot.oom,
            },
        );
    }

    fn report(self: CaseContext, handle: i64) void {
        const snapshot = runtime.runtimeSoakSnapshot(handle) orelse {
            std.debug.print(
                "soak failure: workload={s} seed={d} workers={d} process_cap={d} scale={d} snapshot=stale\n",
                .{ self.name, self.seed, self.workers, self.process_cap, self.scale },
            );
            return;
        };
        std.debug.print(
            "soak failure: workload={s} seed={d} workers={d} process_cap={d} scale={d} " ++
                "phase={d} owner={d} participants={d} initialized={} epoch={d} " ++
                "processes={d}/{d} free={d} runnable={d} waiting={d} done={d} exited={d} owned={d} " ++
                "mailbox={d} results={d} terms={d} max_active={d} migrations={d} " ++
                "arena_chunks={d} arena_bytes={d} arena_high_water={d} oom={}\n",
            .{
                self.name,
                self.seed,
                self.workers,
                self.process_cap,
                self.scale,
                snapshot.lifecycle_phase,
                snapshot.execution_owner,
                snapshot.execution_participants,
                snapshot.execution_initialized,
                snapshot.execution_epoch,
                snapshot.process_count,
                snapshot.process_capacity,
                snapshot.free_count,
                snapshot.runnable,
                snapshot.waiting,
                snapshot.done,
                snapshot.exited,
                snapshot.owned,
                snapshot.mailbox_messages,
                snapshot.outstanding_results,
                snapshot.outstanding_terms,
                snapshot.max_active_actors,
                snapshot.migrations,
                snapshot.arena_chunks,
                snapshot.arena_bytes,
                snapshot.arena_high_water,
                snapshot.oom,
            },
        );
    }
};

const SoakRuntime = struct {
    handle: i64,

    fn init(process_cap: i64) !SoakRuntime {
        const handle = runtime.ex_term_runtime_create();
        if (handle <= 0) return error.RuntimeCreateFailed;
        if (runtime.ex_term_runtime_enter(handle) != 0) return error.RuntimeEnterFailed;
        if (runtime.ex_term_process_table_reset(process_cap) != 1) return error.ProcessResetFailed;
        return .{ .handle = handle };
    }

    fn finish(self: SoakRuntime) !void {
        const before_leave = runtime.runtimeSoakSnapshot(self.handle) orelse return error.StaleRuntime;
        try std.testing.expectEqual(@as(u32, 1), before_leave.execution_participants);
        try std.testing.expectEqual(@as(usize, 0), before_leave.runnable);
        try std.testing.expectEqual(@as(usize, 0), before_leave.waiting);
        try std.testing.expectEqual(@as(usize, 0), before_leave.owned);
        try std.testing.expectEqual(@as(u32, 0), before_leave.outstanding_results);
        try std.testing.expectEqual(@as(u32, 0), before_leave.outstanding_terms);
        try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_runtime_leave());

        const idle = runtime.runtimeSoakSnapshot(self.handle) orelse return error.StaleRuntime;
        try std.testing.expectEqual(@as(u8, 0), idle.lifecycle_phase);
        try std.testing.expectEqual(@as(usize, 0), idle.execution_owner);
        try std.testing.expectEqual(@as(u32, 0), idle.execution_participants);
        try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_runtime_destroy(self.handle));
    }
};

fn waitFor(counter: *std.atomic.Value(u32), expected: u32) bool {
    for (0..10_000_000) |_| {
        if (counter.load(.acquire) == expected) return true;
        std.Thread.yield() catch {};
    }
    return false;
}

const FanInState = struct {
    receiver: i64,
    sender_count: u32,
    messages_per_sender: u32,
    synchronize: bool,
    ready: std.atomic.Value(u32) = .init(0),
    timed_out: std.atomic.Value(bool) = .init(false),
    send_failures: std.atomic.Value(u32) = .init(0),
};

var fan_in_state: *FanInState = undefined;

fn fanInDispatch(_: i64) callconv(.c) i64 {
    const sender = runtime.ex_term_current_entry();
    if (sender == 0) return 0;
    if (fan_in_state.synchronize) {
        _ = fan_in_state.ready.fetchAdd(1, .acq_rel);
        if (!waitFor(&fan_in_state.ready, fan_in_state.sender_count)) {
            fan_in_state.timed_out.store(true, .release);
            return -1;
        }
    }
    for (0..fan_in_state.messages_per_sender) |sequence| {
        const value = (sender - 1) * fan_in_state.messages_per_sender + @as(i64, @intCast(sequence));
        if (runtime.ex_term_send(fan_in_state.receiver, tagged(value)) == nil_word) {
            _ = fan_in_state.send_failures.fetchAdd(1, .acq_rel);
        }
    }
    return tagged(sender);
}

fn runFanIn(config: SoakConfig, workers: i64) !void {
    const process_cap: i64 = 2;
    var soak = try SoakRuntime.init(process_cap);
    const context = CaseContext{
        .name = "fan-in",
        .seed = config.seed,
        .workers = workers,
        .process_cap = process_cap,
        .scale = config.scale,
    };
    errdefer context.report(soak.handle);

    const sender_count: u32 = if (workers == 1) 8 else @intCast(@min(workers, max_senders));
    const messages_per_sender: u32 = @intCast(64 / sender_count);
    const receiver = runtime.ex_term_self();
    var pids: [max_senders]i64 = undefined;
    for (0..sender_count) |index| {
        pids[index] = runtime.ex_term_spawn(@intCast(index + 1));
        try std.testing.expect(pids[index] != nil_word);
    }

    var state = FanInState{
        .receiver = receiver,
        .sender_count = sender_count,
        .messages_per_sender = messages_per_sender,
        .synchronize = workers > 1,
    };
    fan_in_state = &state;
    context.progress(soak.handle, "worker-run");
    _ = runtime.ex_term_worker_run(workers, &fanInDispatch);

    try std.testing.expect(!state.timed_out.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), state.send_failures.load(.acquire));
    const total: usize = sender_count * messages_per_sender;
    try std.testing.expectEqual(@as(i64, @intCast(total)), runtime.ex_term_mailbox_len());

    var next = [_]u32{0} ** max_senders;
    var seen = [_]bool{false} ** 64;
    for (0..total) |_| {
        const value: usize = @intCast(payload(runtime.ex_term_receive()));
        try std.testing.expect(value < total);
        try std.testing.expect(!seen[value]);
        seen[value] = true;
        const sender = value / messages_per_sender;
        const sequence: u32 = @intCast(value % messages_per_sender);
        try std.testing.expectEqual(next[sender], sequence);
        next[sender] += 1;
    }
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_mailbox_len());

    const snapshot = runtime.runtimeSoakSnapshot(soak.handle).?;
    try std.testing.expect(snapshot.process_capacity >= sender_count + 1);
    try std.testing.expectEqual(@as(usize, sender_count), snapshot.free_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.runnable);
    try std.testing.expectEqual(@as(usize, 0), snapshot.owned);
    try std.testing.expectEqual(@as(u32, @intCast(workers)), snapshot.configured_workers);
    try soak.finish();
}

const RingState = struct {
    receiver: i64,
    count: usize,
    token: i64,
    pids: [max_ring_actors]i64 = undefined,
    timed_out: std.atomic.Value(bool) = .init(false),
    send_failures: std.atomic.Value(u32) = .init(0),
};

var ring_state: *RingState = undefined;

fn ringDispatch(_: i64) callconv(.c) i64 {
    const entry = runtime.ex_term_current_entry();
    if (entry == 0) return 0;
    const index: usize = @intCast(entry - 1);
    var message = nil_word;
    for (0..10_000_000) |_| {
        message = runtime.ex_term_receive();
        if (message != nil_word) break;
        std.Thread.yield() catch {};
    }
    if (message == nil_word) {
        ring_state.timed_out.store(true, .release);
        return -1;
    }
    const target = if (index + 1 == ring_state.count) ring_state.receiver else ring_state.pids[index + 1];
    const forwarded = tagged(payload(message) + 1);
    if (runtime.ex_term_send(target, forwarded) == nil_word) {
        _ = ring_state.send_failures.fetchAdd(1, .acq_rel);
    }
    return forwarded;
}

fn runRing(config: SoakConfig, workers: i64) !void {
    const process_cap: i64 = 1;
    var soak = try SoakRuntime.init(process_cap);
    const context = CaseContext{
        .name = "ring",
        .seed = config.seed,
        .workers = workers,
        .process_cap = process_cap,
        .scale = config.scale,
    };
    errdefer context.report(soak.handle);

    const count: usize = if (workers == 1) 16 else @intCast(@min(workers, max_ring_actors));
    var state = RingState{
        .receiver = runtime.ex_term_self(),
        .count = count,
        .token = @intCast(config.seed % 1_000_000),
    };
    for (0..count) |index| {
        state.pids[index] = runtime.ex_term_spawn(@intCast(index + 1));
        try std.testing.expect(state.pids[index] != nil_word);
    }
    ring_state = &state;
    try std.testing.expectEqual(tagged(state.token), runtime.ex_term_send(state.pids[0], tagged(state.token)));
    context.progress(soak.handle, "worker-run");
    _ = runtime.ex_term_worker_run(workers, &ringDispatch);

    try std.testing.expect(!state.timed_out.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), state.send_failures.load(.acquire));
    try std.testing.expectEqual(tagged(state.token + @as(i64, @intCast(count))), runtime.ex_term_receive());
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_mailbox_len());
    const snapshot = runtime.runtimeSoakSnapshot(soak.handle).?;
    try std.testing.expectEqual(count, snapshot.free_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.runnable);
    try std.testing.expectEqual(@as(usize, 0), snapshot.owned);
    try soak.finish();
}

fn findPid(pids: []const i64, pid: i64) ?usize {
    for (pids, 0..) |candidate, index| if (candidate == pid) return index;
    return null;
}

fn runSupervision(config: SoakConfig, workers: i64) !void {
    const process_cap: i64 = 2;
    var soak = try SoakRuntime.init(process_cap);
    const context = CaseContext{
        .name = "supervision",
        .seed = config.seed,
        .workers = workers,
        .process_cap = process_cap,
        .scale = config.scale,
    };
    errdefer context.report(soak.handle);

    const exit_tag: i64 = (201 << int_shift) | 1;
    const down_tag: i64 = (202 << int_shift) | 1;
    const process_tag: i64 = (203 << int_shift) | 1;
    const normal_tag: i64 = (204 << int_shift) | 1;
    const boom: i64 = (205 << int_shift) | 1;
    const parent = runtime.ex_term_self();
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_process_trap_exit(1));
    var pids: [max_children]i64 = undefined;
    for (&pids, 0..) |*pid, index| {
        pid.* = runtime.ex_term_spawn(@intCast(index + 1));
        try std.testing.expectEqual(pid.*, runtime.ex_term_link(pid.*, exit_tag, normal_tag));
        try std.testing.expect(runtime.ex_term_monitor(pid.*, down_tag, process_tag, normal_tag) != nil_word);
    }

    for (pids, 0..) |pid, index| {
        try std.testing.expectEqual(pid, runtime.ex_term_schedule_next());
        if (@mod(index + 1, 2) == 1) {
            try std.testing.expectEqual(boom, runtime.ex_term_process_exit(boom));
        } else {
            try std.testing.expectEqual(tagged(@intCast(index + 1)), runtime.ex_term_process_done(tagged(@intCast(index + 1))));
        }
    }
    try std.testing.expectEqual(parent, runtime.ex_term_schedule_next());
    try std.testing.expectEqual(@as(i64, max_children * 2), runtime.ex_term_mailbox_len());

    var saw_exit = [_]bool{false} ** max_children;
    var saw_down = [_]bool{false} ** max_children;
    for (0..max_children * 2) |_| {
        const signal = runtime.ex_term_receive();
        const tag = runtime.ex_term_tuple_get(signal, 0);
        if (tag == exit_tag) {
            const pid = runtime.ex_term_tuple_get(signal, 1);
            const index = findPid(&pids, pid) orelse return error.UnknownExitPid;
            try std.testing.expect(!saw_exit[index]);
            saw_exit[index] = true;
            const expected = if (@mod(index + 1, 2) == 1) boom else normal_tag;
            try std.testing.expectEqual(expected, runtime.ex_term_tuple_get(signal, 2));
        } else if (tag == down_tag) {
            const pid = runtime.ex_term_tuple_get(signal, 3);
            const index = findPid(&pids, pid) orelse return error.UnknownDownPid;
            try std.testing.expect(saw_exit[index]);
            try std.testing.expect(!saw_down[index]);
            saw_down[index] = true;
            const expected = if (@mod(index + 1, 2) == 1) boom else normal_tag;
            try std.testing.expectEqual(expected, runtime.ex_term_tuple_get(signal, 4));
        } else {
            return error.UnknownSignal;
        }
    }
    for (0..max_children) |index| {
        try std.testing.expect(saw_exit[index]);
        try std.testing.expect(saw_down[index]);
    }
    _ = runtime.ex_term_process_done(0);
    const snapshot = runtime.runtimeSoakSnapshot(soak.handle).?;
    try std.testing.expectEqual(@as(usize, max_children / 2), snapshot.exited);
    try std.testing.expectEqual(@as(usize, max_children / 2 + 1), snapshot.done);
    try std.testing.expectEqual(@as(usize, max_children), snapshot.free_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.owned);
    try soak.finish();
}

fn runSelectiveReceive(config: SoakConfig) !void {
    const process_cap: i64 = 1;
    var soak = try SoakRuntime.init(process_cap);
    const context = CaseContext{
        .name = "selective-receive",
        .seed = config.seed,
        .workers = 1,
        .process_cap = process_cap,
        .scale = config.scale,
    };
    errdefer context.report(soak.handle);

    const rounds = 16 * config.scale;
    const receiver = runtime.ex_term_self();
    for (0..rounds) |round| {
        _ = runtime.ex_term_mailbox_clear();
        for (0..62) |index| {
            try std.testing.expectEqual(tagged(@intCast(index)), runtime.ex_term_send(receiver, tagged(@intCast(index))));
        }
        const target = tagged(@intCast(1_000_000 + round));
        try std.testing.expectEqual(target, runtime.ex_term_send(receiver, target));
        try std.testing.expectEqual(@as(i64, 63), runtime.ex_term_mailbox_len());

        var cursor: i64 = 0;
        while (cursor < runtime.ex_term_mailbox_len() and runtime.ex_term_mailbox_peek(cursor) != target) : (cursor += 1) {}
        try std.testing.expectEqual(@as(i64, 62), cursor);
        try std.testing.expectEqual(@as(i64, 1), runtime.ex_term_mailbox_remove(cursor));
        for (0..62) |index| {
            try std.testing.expectEqual(tagged(@intCast(index)), runtime.ex_term_receive());
        }
        try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_mailbox_len());
    }
    _ = runtime.ex_term_process_done(0);
    try soak.finish();
}

fn runRecycle(config: SoakConfig) !void {
    const process_cap: i64 = 2;
    var soak = try SoakRuntime.init(process_cap);
    const context = CaseContext{
        .name = "process-recycle",
        .seed = config.seed,
        .workers = 1,
        .process_cap = process_cap,
        .scale = config.scale,
    };
    errdefer context.report(soak.handle);

    const receiver = runtime.ex_term_self();
    const cycles = 128 * config.scale;
    var stale_pid: i64 = nil_word;
    for (0..cycles) |cycle| {
        const pid = runtime.ex_term_spawn(1);
        try std.testing.expect(pid != nil_word);
        if (stale_pid != nil_word) {
            try std.testing.expectEqual(nil_word, runtime.ex_term_send(stale_pid, tagged(@intCast(cycle))));
        }
        try std.testing.expectEqual(pid, runtime.ex_term_schedule_next());
        const composite = runtime.ex_term_list_cons(
            tagged(@intCast(cycle)),
            runtime.ex_term_list_cons(tagged(@intCast(cycle + 1)), nil_word),
        );
        try std.testing.expectEqual(composite, runtime.ex_term_send(receiver, composite));
        _ = runtime.ex_term_process_done(tagged(@intCast(cycle)));
        try std.testing.expectEqual(receiver, runtime.ex_term_schedule_next());

        const retained = runtime.ex_term_receive();
        try std.testing.expectEqual(tagged(@intCast(cycle)), runtime.ex_term_list_head(retained));
        try std.testing.expectEqual(
            tagged(@intCast(cycle + 1)),
            runtime.ex_term_list_head(runtime.ex_term_list_tail(retained)),
        );
        stale_pid = pid;
    }
    const replacement = runtime.ex_term_spawn(1);
    try std.testing.expect(replacement != stale_pid);
    try std.testing.expectEqual(nil_word, runtime.ex_term_send(stale_pid, tagged(1)));
    try std.testing.expectEqual(replacement, runtime.ex_term_schedule_next());
    _ = runtime.ex_term_process_done(0);
    try std.testing.expectEqual(receiver, runtime.ex_term_schedule_next());
    const snapshot = runtime.runtimeSoakSnapshot(soak.handle).?;
    try std.testing.expectEqual(@as(usize, 2), snapshot.process_count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.free_count);
    try std.testing.expect(snapshot.arena_high_water > 0);
    _ = runtime.ex_term_process_done(0);
    try soak.finish();
}

const CompositeTermState = struct {
    receiver: i64,
    allocations_per_actor: usize,
    failures: std.atomic.Value(u32) = .init(0),
};

var composite_term_state: *CompositeTermState = undefined;

fn compositeTermDispatch(_: i64) callconv(.c) i64 {
    const actor = runtime.ex_term_current_entry();
    if (actor == 0) return 0;
    var list = nil_word;
    for (0..composite_term_state.allocations_per_actor) |index| {
        list = runtime.ex_term_list_cons(tagged(@intCast(index)), list);
        if (list == nil_word) {
            _ = composite_term_state.failures.fetchAdd(1, .acq_rel);
            return -1;
        }
    }
    const composite = runtime.ex_term_list_cons(tagged(actor), runtime.ex_term_list_cons(list, nil_word));
    if (runtime.ex_term_send(composite_term_state.receiver, composite) == nil_word) {
        _ = composite_term_state.failures.fetchAdd(1, .acq_rel);
    }
    return tagged(actor);
}

fn runCompositeTerms(config: SoakConfig, workers: i64) !void {
    const process_cap: i64 = 2;
    var soak = try SoakRuntime.init(process_cap);
    const context = CaseContext{
        .name = "composite-arena",
        .seed = config.seed,
        .workers = workers,
        .process_cap = process_cap,
        .scale = config.scale,
    };
    errdefer context.report(soak.handle);

    const actor_count: usize = 16;
    const allocations_per_actor = 5_000 * config.scale;
    const receiver = runtime.ex_term_self();
    var stale_pids: [actor_count]i64 = undefined;
    for (&stale_pids, 0..) |*pid, index| {
        pid.* = runtime.ex_term_spawn(@intCast(index + 1));
        try std.testing.expect(pid.* != nil_word);
    }
    var state = CompositeTermState{
        .receiver = receiver,
        .allocations_per_actor = allocations_per_actor,
    };
    composite_term_state = &state;
    context.progress(soak.handle, "worker-run");
    _ = runtime.ex_term_worker_run(workers, &compositeTermDispatch);
    try std.testing.expectEqual(@as(u32, 0), state.failures.load(.acquire));
    try std.testing.expectEqual(@as(i64, actor_count), runtime.ex_term_mailbox_len());

    var seen = [_]bool{false} ** actor_count;
    for (0..actor_count) |_| {
        const composite = runtime.ex_term_receive();
        const actor: usize = @intCast(payload(runtime.ex_term_list_head(composite)) - 1);
        try std.testing.expect(actor < actor_count);
        try std.testing.expect(!seen[actor]);
        seen[actor] = true;
        const nested = runtime.ex_term_list_head(runtime.ex_term_list_tail(composite));
        try std.testing.expectEqual(tagged(@intCast(allocations_per_actor - 1)), runtime.ex_term_list_head(nested));
        try std.testing.expectEqual(@as(i64, @intCast(allocations_per_actor)), runtime.ex_term_list_length(nested));
    }

    var replacements: [actor_count]i64 = undefined;
    for (&replacements, 0..) |*replacement, index| {
        replacement.* = runtime.ex_term_spawn(@intCast(index + 1));
        try std.testing.expect(replacement.* != nil_word);
    }
    for (stale_pids) |stale| try std.testing.expectEqual(nil_word, runtime.ex_term_send(stale, tagged(1)));
    for (replacements) |_| {
        const replacement = runtime.ex_term_schedule_next();
        try std.testing.expect(findPid(&replacements, replacement) != null);
        _ = runtime.ex_term_process_done(0);
    }
    const snapshot = runtime.runtimeSoakSnapshot(soak.handle).?;
    try std.testing.expect(snapshot.arena_chunks > 1);
    try std.testing.expect(snapshot.arena_high_water >= actor_count * allocations_per_actor * 2 * @sizeOf(i64));
    try std.testing.expectEqual(actor_count, snapshot.free_count);
    try std.testing.expectEqual(@as(usize, 0), snapshot.mailbox_messages);
    try soak.finish();
}

fn runControlledOom(config: SoakConfig) !void {
    const process_cap: i64 = 1;
    var soak = try SoakRuntime.init(process_cap);
    const context = CaseContext{
        .name = "controlled-oom",
        .seed = config.seed,
        .workers = 1,
        .process_cap = process_cap,
        .scale = config.scale,
    };
    errdefer context.report(soak.handle);

    try std.testing.expect(runtime.runtimeSoakForceOom(soak.handle));
    const failed = runtime.runtimeSoakSnapshot(soak.handle).?;
    try std.testing.expect(failed.oom);
    try std.testing.expectEqual(@as(usize, 1), failed.runnable);
    try std.testing.expectEqual(@as(usize, 0), failed.owned);
    try std.testing.expectEqual(@as(u32, 1), failed.execution_participants);
    try std.testing.expectEqual(@as(u32, 0), failed.outstanding_results);
    try std.testing.expectEqual(@as(u32, 0), failed.outstanding_terms);
    _ = runtime.ex_term_process_done(0);
    try soak.finish();
}

fn runPortableActorBoundary(config: SoakConfig) !void {
    const source = try SoakRuntime.init(2);
    const source_context = CaseContext{
        .name = "actor-export-import",
        .seed = config.seed,
        .workers = 1,
        .process_cap = 2,
        .scale = config.scale,
    };
    errdefer source_context.report(source.handle);

    const parent = runtime.ex_term_self();
    const sender = runtime.ex_term_spawn(1);
    try std.testing.expectEqual(sender, runtime.ex_term_schedule_next());
    const composite = runtime.ex_term_list_cons(tagged(41), runtime.ex_term_list_cons(tagged(42), nil_word));
    try std.testing.expectEqual(composite, runtime.ex_term_send(parent, composite));
    _ = runtime.ex_term_process_done(0);
    try std.testing.expectEqual(parent, runtime.ex_term_schedule_next());
    const retained = runtime.ex_term_receive();
    try std.testing.expectEqual(tagged(41), runtime.ex_term_list_head(retained));
    _ = runtime.ex_term_process_done(0);

    const result = runtime.ex_term_result_create(source.handle, retained);
    try std.testing.expect(result > 0);
    const pinned = runtime.runtimeSoakSnapshot(source.handle).?;
    try std.testing.expectEqual(@as(u32, 1), pinned.outstanding_results);
    try std.testing.expectEqual(@as(u32, 0), pinned.outstanding_terms);
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_runtime_leave());

    const exported = runtime.ex_term_export(result, retained);
    try std.testing.expect(exported > 0);
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_result_destroy(result));
    try std.testing.expect(runtime.runtimeSoakSnapshot(source.handle) == null);

    const target = try SoakRuntime.init(1);
    const target_context = CaseContext{
        .name = "actor-export-import-target",
        .seed = config.seed,
        .workers = 1,
        .process_cap = 1,
        .scale = config.scale,
    };
    errdefer target_context.report(target.handle);
    const term = runtime.ex_term_import(target.handle, exported);
    try std.testing.expect(term > 0);
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_runtime_leave());
    const target_pinned = runtime.runtimeSoakSnapshot(target.handle).?;
    try std.testing.expectEqual(@as(u32, 0), target_pinned.outstanding_results);
    try std.testing.expectEqual(@as(u32, 1), target_pinned.outstanding_terms);

    const copy = runtime.ex_term_handle_export(term);
    try std.testing.expect(copy > 0);
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_handle_destroy(term));
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_runtime_destroy(target.handle));
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_exported_destroy(copy));
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_exported_destroy(exported));
}

test "soak fan-in preserves counts uniqueness and per-sender ordering" {
    const config = SoakConfig.load();
    for ([_]i64{ 1, 2, 4, 8, 64 }) |workers| try runFanIn(config, workers);
}

test "soak ring forwards one token across worker and growth matrices" {
    const config = SoakConfig.load();
    for ([_]i64{ 1, 2, 4, 8, 64 }) |workers| try runRing(config, workers);
}

test "soak supervision orders EXIT before DOWN and isolates actor failures" {
    const config = SoakConfig.load();
    try runSupervision(config, 1);
}

test "soak selective receive scans a full mailbox without loss" {
    try runSelectiveReceive(SoakConfig.load());
}

test "soak process slots reject stale pids across repeated reuse" {
    try runRecycle(SoakConfig.load());
}

test "soak composite terms survive sender exit and multi-segment arena growth" {
    const config = SoakConfig.load();
    for ([_]i64{ 1, 8, 64 }) |workers| try runCompositeTerms(config, workers);
}

test "soak controlled OOM leaves lifecycle ownership and pins consistent" {
    try runControlledOom(SoakConfig.load());
}

test "soak actor result export and import release every runtime pin" {
    try runPortableActorBoundary(SoakConfig.load());
}
