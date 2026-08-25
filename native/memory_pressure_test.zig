const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const c = @cImport({
    @cInclude("stdlib.h");
});

const nil_word: i64 = 1;
const int_shift = 3;

const Config = struct {
    workload: []const u8,
    seed: u64,
    iterations: usize,
    quota_bytes: i64,
    scale: usize,
    workers: i64,
    runtimes: usize,
    cycles: usize,

    fn load() Config {
        return .{
            .workload = env("BATATA_PRESSURE_WORKLOAD") orelse "composite-arena",
            .seed = parseEnvInt(u64, "BATATA_PRESSURE_SEED", 0x107),
            .iterations = parseEnvInt(usize, "BATATA_PRESSURE_ITERATIONS", 4_097),
            .quota_bytes = parseEnvInt(i64, "BATATA_PRESSURE_QUOTA_BYTES", 65_536),
            .scale = parseEnvInt(usize, "BATATA_PRESSURE_SCALE", 1),
            .workers = parseEnvInt(i64, "BATATA_PRESSURE_WORKERS", 1),
            .runtimes = parseEnvInt(usize, "BATATA_PRESSURE_RUNTIMES", 2),
            .cycles = parseEnvInt(usize, "BATATA_PRESSURE_CYCLES", 2),
        };
    }

    fn allocationCount(self: Config) !usize {
        return std.math.mul(usize, self.iterations, self.scale) catch error.IterationOverflow;
    }
};

fn env(comptime name: [:0]const u8) ?[]const u8 {
    const value = c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn parseEnvInt(comptime T: type, comptime name: [:0]const u8, default: T) T {
    const value = env(name) orelse return default;
    return std.fmt.parseInt(T, value, 0) catch default;
}

fn peakRssBytes() ?u64 {
    return switch (builtin.os.tag) {
        .linux, .macos => blk: {
            const max_rss = std.posix.getrusage(0).maxrss;
            if (max_rss < 0) break :blk null;
            const raw: u64 = @intCast(max_rss);
            break :blk if (builtin.os.tag == .linux) raw * 1024 else raw;
        },
        else => null,
    };
}

fn tagged(value: i64) i64 {
    return value << int_shift;
}

fn composite(iteration: usize, seed: u64) void {
    var bytes: [128]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(seed + iteration + index);
    const length: usize = 16 + ((seed + iteration) % 113);
    const binary = runtime.ex_term_binary_from_bytes(&bytes, @intCast(length));
    var list = runtime.ex_term_list_cons(binary, nil_word);
    list = runtime.ex_term_list_cons(tagged(@intCast(iteration)), list);
    _ = runtime.ex_term_tuple_from_list(list);
}

fn quotaBoundary(iteration: usize) void {
    _ = runtime.ex_term_list_cons(tagged(@intCast(iteration)), nil_word);
}

const Report = struct {
    arena_capacity_bytes: usize,
    arena_chunks: usize,
    arena_high_water_bytes: usize,
    aggregate_high_water_bytes: usize,
    oom: bool,
    resets: usize = 0,
    exports: usize = 0,
    imports: usize = 0,
    runtime_count: usize = 1,
    lifecycle_closed: bool = false,
    arena_capacity_growth_bytes: usize = 0,
    pin_reset_rejections: usize = 0,
    post_pin_resets: usize = 0,
    retained_exported_peak_bytes: usize = 0,
    retained_exported_final_bytes: usize = 0,
    source_runtime_destroyed: bool = false,
};

const WorkerPressureState = struct {
    allocations_per_actor: usize,
    quota_boundary: bool,
    failures: std.atomic.Value(u32) = .init(0),
};

var worker_pressure_state: *WorkerPressureState = undefined;

fn workerPressureDispatch(_: i64) callconv(.c) i64 {
    const actor = runtime.ex_term_current_entry();
    if (actor == 0) return 0;
    for (0..worker_pressure_state.allocations_per_actor) |iteration| {
        if (worker_pressure_state.quota_boundary) {
            quotaBoundary(iteration);
        } else {
            composite(iteration, @intCast(actor));
        }
        if (runtime.ex_term_list_cons(tagged(@intCast(iteration)), nil_word) == nil_word) {
            _ = worker_pressure_state.failures.fetchAdd(1, .acq_rel);
            return -1;
        }
    }
    return tagged(actor);
}

fn createEntered(config: Config) !i64 {
    const handle = try createConfigured(config);
    try enterReset(handle);
    return handle;
}

fn createConfigured(config: Config) !i64 {
    const handle = runtime.ex_term_runtime_create();
    if (handle <= 0) return error.RuntimeCreateFailed;
    if (runtime.ex_term_runtime_set_arena_limit(handle, config.quota_bytes) != 0)
        return error.InvalidQuota;
    return handle;
}

fn enterReset(handle: i64) !void {
    if (runtime.ex_term_runtime_enter(handle) != 0) return error.RuntimeEnterFailed;
    if (runtime.ex_term_process_table_reset(256) != 1) return error.ProcessResetFailed;
}

fn reportFromSnapshot(snapshot: runtime.RuntimeSoakSnapshot) Report {
    return .{
        .arena_capacity_bytes = snapshot.arena_bytes,
        .arena_chunks = snapshot.arena_chunks,
        .arena_high_water_bytes = snapshot.arena_high_water,
        .aggregate_high_water_bytes = snapshot.arena_high_water,
        .oom = snapshot.oom,
    };
}

fn allocateSelected(handle: i64, config: Config, count: usize) void {
    for (0..count) |iteration| {
        if (std.mem.eql(u8, config.workload, "composite-arena") or
            std.mem.eql(u8, config.workload, "reset-reuse"))
        {
            composite(iteration, config.seed);
        } else {
            quotaBoundary(iteration);
        }
        if (runtime.ex_term_runtime_oom(handle) == 1) break;
    }
}

fn allocatePressure(handle: i64, config: Config, count: usize) !void {
    if (config.workers == 1) {
        allocateSelected(handle, config, count);
        return;
    }

    const actor_count: usize = @min(@as(usize, @intCast(config.workers * 2)), 128);
    for (0..actor_count) |index| {
        if (runtime.ex_term_spawn(@intCast(index + 1)) == nil_word) return error.SpawnFailed;
    }
    var state = WorkerPressureState{
        .allocations_per_actor = @max(count / actor_count, 1),
        .quota_boundary = std.mem.eql(u8, config.workload, "quota-boundary"),
    };
    worker_pressure_state = &state;
    if (runtime.ex_term_worker_run(config.workers, &workerPressureDispatch) < 0)
        return error.WorkerRunFailed;
}

fn runSingle(config: Config) !Report {
    const handle = try createEntered(config);
    try allocatePressure(handle, config, try config.allocationCount());
    const snapshot = runtime.runtimeSoakSnapshot(handle) orelse return error.StaleRuntime;
    var report = reportFromSnapshot(snapshot);
    if (runtime.ex_term_runtime_leave() != 0) return error.RuntimeLeaveFailed;
    if (runtime.ex_term_runtime_destroy(handle) != 0) return error.RuntimeDestroyFailed;
    report.lifecycle_closed = true;
    return report;
}

fn runResetReuse(config: Config) !Report {
    const handle = try createConfigured(config);
    var report = Report{
        .arena_capacity_bytes = 0,
        .arena_chunks = 0,
        .arena_high_water_bytes = 0,
        .aggregate_high_water_bytes = 0,
        .oom = false,
    };
    var first_capacity: usize = 0;

    for (0..config.cycles) |cycle| {
        try enterReset(handle);
        const reset = runtime.runtimeSoakSnapshot(handle) orelse return error.StaleRuntime;
        if (reset.arena_high_water != 0 or reset.oom) return error.ResetDidNotClearArena;
        try allocatePressure(handle, config, try config.allocationCount());
        const snapshot = runtime.runtimeSoakSnapshot(handle) orelse return error.StaleRuntime;
        if (snapshot.arena_high_water == 0) return error.NoPressure;
        if (cycle == 0) first_capacity = snapshot.arena_bytes;
        report.arena_capacity_bytes = snapshot.arena_bytes;
        report.arena_chunks = snapshot.arena_chunks;
        report.arena_high_water_bytes = @max(report.arena_high_water_bytes, snapshot.arena_high_water);
        report.aggregate_high_water_bytes += snapshot.arena_high_water;
        report.oom = report.oom or snapshot.oom;
        if (runtime.ex_term_runtime_leave() != 0) return error.RuntimeLeaveFailed;
    }

    report.resets = config.cycles;
    report.arena_capacity_growth_bytes = report.arena_capacity_bytes - first_capacity;
    if (runtime.ex_term_runtime_destroy(handle) != 0) return error.RuntimeDestroyFailed;
    report.lifecycle_closed = true;
    return report;
}

fn buildPortableBinary(config: Config) !i64 {
    const quota: usize = @intCast(config.quota_bytes);
    const length = @max(@min(config.iterations, quota / 2), 1);
    const bytes = try std.heap.page_allocator.alloc(u8, length);
    defer std.heap.page_allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(config.seed + index);
    return runtime.ex_term_binary_from_bytes(bytes.ptr, @intCast(length));
}

fn runExportImport(config: Config) !Report {
    if (config.workers != 1 or config.runtimes != 2) return error.InvalidCombination;
    const source = try createEntered(config);
    const root = try buildPortableBinary(config);
    const source_snapshot = runtime.runtimeSoakSnapshot(source) orelse return error.StaleRuntime;
    const result = runtime.ex_term_result_create(source, root);
    if (result <= 0) return error.ResultCreateFailed;
    if (runtime.ex_term_runtime_leave() != 0) return error.RuntimeLeaveFailed;
    const exported = runtime.ex_term_export(result, root);
    if (exported <= 0) return error.ExportFailed;
    const retained_peak = runtime.exportedSoakBytes();
    if (runtime.ex_term_runtime_enter(source) != -2) return error.PinDidNotRejectReset;
    if (runtime.ex_term_result_destroy(result) != 0) return error.ResultDestroyFailed;
    if (runtime.runtimeSoakSnapshot(source) != null) return error.SourceRuntimeRetained;

    const target = try createEntered(config);
    const imported = runtime.ex_term_import(target, exported);
    if (imported <= 0) return error.ImportFailed;
    const target_snapshot = runtime.runtimeSoakSnapshot(target) orelse return error.StaleRuntime;
    if (runtime.ex_term_runtime_leave() != 0) return error.RuntimeLeaveFailed;
    const round_trip = runtime.ex_term_handle_export(imported);
    if (round_trip <= 0) return error.ExportFailed;
    if (runtime.ex_term_runtime_enter(target) != -2) return error.PinDidNotRejectReset;
    if (runtime.ex_term_handle_destroy(imported) != 0) return error.TermDestroyFailed;
    try enterReset(target);
    if (runtime.ex_term_runtime_leave() != 0) return error.RuntimeLeaveFailed;
    if (runtime.ex_term_runtime_destroy(target) != 0) return error.RuntimeDestroyFailed;
    if (runtime.ex_term_exported_destroy(round_trip) != 0) return error.ExportedDestroyFailed;
    if (runtime.ex_term_exported_destroy(exported) != 0) return error.ExportedDestroyFailed;

    var report = reportFromSnapshot(target_snapshot);
    report.arena_capacity_bytes = @max(source_snapshot.arena_bytes, target_snapshot.arena_bytes);
    report.arena_chunks = source_snapshot.arena_chunks + target_snapshot.arena_chunks;
    report.arena_high_water_bytes = @max(
        source_snapshot.arena_high_water,
        target_snapshot.arena_high_water,
    );
    report.aggregate_high_water_bytes =
        source_snapshot.arena_high_water + target_snapshot.arena_high_water;
    report.oom = source_snapshot.oom or target_snapshot.oom;
    report.exports = 2;
    report.imports = 1;
    report.runtime_count = 2;
    report.pin_reset_rejections = 2;
    report.post_pin_resets = 1;
    report.retained_exported_peak_bytes = retained_peak;
    report.retained_exported_final_bytes = runtime.exportedSoakBytes();
    report.source_runtime_destroyed = true;
    report.lifecycle_closed = true;
    return report;
}

const MultiRuntimeState = struct {
    config: Config,
    index: usize,
    snapshot: runtime.RuntimeSoakSnapshot = undefined,
    failed: bool = false,
};

fn multiRuntimeWorker(state: *MultiRuntimeState) void {
    const count = state.config.allocationCount() catch {
        state.failed = true;
        return;
    };
    const handle = createEntered(state.config) catch {
        state.failed = true;
        return;
    };
    for (0..count) |iteration| {
        composite(iteration, state.config.seed + state.index);
        if (runtime.ex_term_runtime_oom(handle) == 1) break;
    }
    state.snapshot = runtime.runtimeSoakSnapshot(handle) orelse {
        state.failed = true;
        return;
    };
    if (runtime.ex_term_runtime_leave() != 0 or runtime.ex_term_runtime_destroy(handle) != 0) {
        state.failed = true;
    }
}

fn runMultiRuntime(config: Config) !Report {
    if (config.workers != 1) return error.InvalidCombination;
    var states: [8]MultiRuntimeState = undefined;
    var threads: [8]std.Thread = undefined;
    for (0..config.runtimes) |index| {
        states[index] = .{ .config = config, .index = index };
        threads[index] = try std.Thread.spawn(.{}, multiRuntimeWorker, .{&states[index]});
    }
    for (threads[0..config.runtimes]) |thread| thread.join();

    var report = Report{
        .arena_capacity_bytes = 0,
        .arena_chunks = 0,
        .arena_high_water_bytes = 0,
        .aggregate_high_water_bytes = 0,
        .oom = false,
        .runtime_count = config.runtimes,
        .lifecycle_closed = true,
    };
    for (states[0..config.runtimes]) |state| {
        if (state.failed) return error.ConcurrentRuntimeFailed;
        report.arena_capacity_bytes = @max(report.arena_capacity_bytes, state.snapshot.arena_bytes);
        report.arena_chunks += state.snapshot.arena_chunks;
        report.arena_high_water_bytes =
            @max(report.arena_high_water_bytes, state.snapshot.arena_high_water);
        report.aggregate_high_water_bytes += state.snapshot.arena_high_water;
        report.oom = report.oom or state.snapshot.oom;
    }
    return report;
}

test "deterministic selected memory-pressure workload emits a replay snapshot" {
    const config = Config.load();
    if (config.iterations == 0 or config.scale == 0 or config.cycles == 0)
        return error.InvalidIterations;
    if (config.quota_bytes < 0) return error.InvalidQuota;
    if (config.workers < 1 or config.workers > 64) return error.InvalidWorkers;
    if (config.runtimes < 1 or config.runtimes > 8) return error.InvalidRuntimes;
    const report = if (std.mem.eql(u8, config.workload, "composite-arena") or
        std.mem.eql(u8, config.workload, "quota-boundary"))
        try runSingle(config)
    else if (std.mem.eql(u8, config.workload, "reset-reuse"))
        try runResetReuse(config)
    else if (std.mem.eql(u8, config.workload, "export-import"))
        try runExportImport(config)
    else if (std.mem.eql(u8, config.workload, "multi-runtime"))
        try runMultiRuntime(config)
    else
        return error.InvalidWorkload;
    const rss_peak = peakRssBytes();

    std.debug.print(
        "BATATA_PRESSURE {{\"arena_capacity_bytes\":{d},\"arena_chunks\":{d}," ++
            "\"arena_high_water_bytes\":{d},\"aggregate_high_water_bytes\":{d}," ++
            "\"arena_capacity_growth_bytes\":{d},\"cycles\":{d}," ++
            "\"exports\":{d},\"imports\":{d},\"iterations\":{d}," ++
            "\"lifecycle_closed\":{},\"oom\":{},\"quota_bytes\":{d}," ++
            "\"pin_reset_rejections\":{d},\"post_pin_resets\":{d}," ++
            "\"resets\":{d},\"retained_exported_final_bytes\":{d}," ++
            "\"retained_exported_peak_bytes\":{d},\"runtime_count\":{d}," ++
            "\"rss_available\":{},\"rss_peak_bytes\":{d}," ++
            "\"scale\":{d},\"seed\":{d},\"source_runtime_destroyed\":{}," ++
            "\"workers\":{d}," ++
            "\"workload\":\"{s}\"}}\n",
        .{
            report.arena_capacity_bytes,
            report.arena_chunks,
            report.arena_high_water_bytes,
            report.aggregate_high_water_bytes,
            report.arena_capacity_growth_bytes,
            config.cycles,
            report.exports,
            report.imports,
            config.iterations,
            report.lifecycle_closed,
            report.oom,
            config.quota_bytes,
            report.pin_reset_rejections,
            report.post_pin_resets,
            report.resets,
            report.retained_exported_final_bytes,
            report.retained_exported_peak_bytes,
            report.runtime_count,
            rss_peak != null,
            rss_peak orelse 0,
            config.scale,
            config.seed,
            report.source_runtime_destroyed,
            config.workers,
            config.workload,
        },
    );

    try std.testing.expect(report.arena_high_water_bytes <= @as(usize, @intCast(config.quota_bytes)));
    try std.testing.expect(report.lifecycle_closed);
}
