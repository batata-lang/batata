const std = @import("std");
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

    fn load() Config {
        return .{
            .workload = env("BATATA_PRESSURE_WORKLOAD") orelse "composite-arena",
            .seed = parseEnvInt(u64, "BATATA_PRESSURE_SEED", 0x107),
            .iterations = parseEnvInt(usize, "BATATA_PRESSURE_ITERATIONS", 4_097),
            .quota_bytes = parseEnvInt(i64, "BATATA_PRESSURE_QUOTA_BYTES", 65_536),
        };
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

test "deterministic selected memory-pressure workload emits a replay snapshot" {
    const config = Config.load();
    if (config.iterations == 0) return error.InvalidIterations;
    if (config.quota_bytes < 0) return error.InvalidQuota;
    if (!std.mem.eql(u8, config.workload, "composite-arena") and
        !std.mem.eql(u8, config.workload, "quota-boundary")) return error.InvalidWorkload;

    const handle = runtime.ex_term_runtime_create();
    if (handle <= 0) return error.RuntimeCreateFailed;
    if (runtime.ex_term_runtime_set_arena_limit(handle, config.quota_bytes) != 0)
        return error.InvalidQuota;
    if (runtime.ex_term_runtime_enter(handle) != 0) return error.RuntimeEnterFailed;
    if (runtime.ex_term_process_table_reset(256) != 1) return error.ProcessResetFailed;

    for (0..config.iterations) |iteration| {
        if (std.mem.eql(u8, config.workload, "composite-arena")) {
            composite(iteration, config.seed);
        } else {
            quotaBoundary(iteration);
        }
        if (runtime.ex_term_runtime_oom(handle) == 1) break;
    }

    const snapshot = runtime.runtimeSoakSnapshot(handle) orelse return error.StaleRuntime;
    std.debug.print(
        "BATATA_PRESSURE {{\"arena_capacity_bytes\":{d},\"arena_chunks\":{d}," ++
            "\"arena_high_water_bytes\":{d},\"iterations\":{d},\"oom\":{}," ++
            "\"quota_bytes\":{d},\"seed\":{d},\"workload\":\"{s}\"}}\n",
        .{
            snapshot.arena_bytes,
            snapshot.arena_chunks,
            snapshot.arena_high_water,
            config.iterations,
            snapshot.oom,
            config.quota_bytes,
            config.seed,
            config.workload,
        },
    );

    try std.testing.expect(snapshot.arena_high_water <= @as(usize, @intCast(config.quota_bytes)));
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_runtime_leave());
    try std.testing.expectEqual(@as(i64, 0), runtime.ex_term_runtime_destroy(handle));
}
