const std = @import("std");
const json_output = @import("json_output");
const c = @cImport({
    @cInclude("time.h");
});
const runtime = @import("runtime");

// #50 benchmark: a long-running runtime creating short-lived actors. With
// slot recycling (stage 1), a small process table sustains an unbounded
// number of spawn+complete cycles and never grows past the concurrency peak;
// with dynamic growth (stage 2), a burst of spawns without completion grows
// the table to the cumulative count instead of failing. The two last-pid
// indices contrast the table sizes.
//
// Run: zig run -O ReleaseFast --dep runtime \
//   -Mroot=bench/process_reuse.zig -Mruntime=native/term_runtime.zig -lc

const iterations: usize = 1_000_000;
const cap: i64 = 8;

const BenchmarkReport = struct {
    spawns: usize,
    cap: i64,
    reuse_success: usize,
    reuse_last_index: usize,
    reuse_peak_runnable: i64,
    reuse_elapsed_us: u64,
    no_reuse_last_index: usize,
    no_reuse_failures: usize,
    no_reuse_elapsed_us: u64,
};

fn pid_index(pid: i64) usize {
    const payload = @as(u64, @bitCast(pid)) >> 3;
    return @intCast((payload & 0xFFFFFF) - 1);
}

fn now_ns() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn short_lived(pid: i64) callconv(.c) i64 {
    return pid;
}

pub fn main() !void {
    // Reuse mode: spawn -> claim -> complete, repeatedly. The completed slot
    // is recycled, so every spawn succeeds and the table never fills.
    const handle = runtime.ex_term_runtime_create();
    _ = runtime.ex_term_runtime_enter(handle);
    _ = runtime.ex_term_process_table_reset(cap);
    // Park the entry process first so claims below always hit the fresh actor.
    _ = runtime.ex_term_process_claim_next(1);
    _ = runtime.ex_term_process_done(1);

    var spawned: usize = 0;
    var peak_runnable: i64 = 0;
    var reuse_last_index: usize = 0;
    const start = now_ns();
    while (spawned < iterations) : (spawned += 1) {
        const pid = runtime.ex_term_spawn(1);
        if (pid == 1) break; // nil: table full (should not happen with reuse)
        reuse_last_index = pid_index(pid);
        const runnable = runtime.ex_term_processes_runnable();
        if (runnable > peak_runnable) peak_runnable = runnable;
        _ = runtime.ex_term_process_claim_next(1);
        _ = runtime.ex_term_process_done(pid);
    }
    const reuse_us = (now_ns() - start) / 1000;
    _ = runtime.ex_term_runtime_destroy(handle);

    // Baseline without recycling: spawn without completing. The table grows
    // dynamically (#50 stage 2) to the cumulative spawn count.
    const handle2 = runtime.ex_term_runtime_create();
    _ = runtime.ex_term_runtime_enter(handle2);
    _ = runtime.ex_term_process_table_reset(cap);
    var failures: usize = 0;
    var no_reuse_last_index: usize = 0;
    const baseline_start = now_ns();
    for (0..iterations) |_| {
        const pid = runtime.ex_term_spawn(1);
        if (pid == 1) {
            failures += 1;
        } else {
            no_reuse_last_index = pid_index(pid);
        }
    }
    const baseline_us = now_ns() - baseline_start;
    _ = runtime.ex_term_runtime_destroy(handle2);

    try json_output.writeStderr("", BenchmarkReport{
        .spawns = iterations,
        .cap = cap,
        .reuse_success = spawned,
        .reuse_last_index = reuse_last_index,
        .reuse_peak_runnable = peak_runnable,
        .reuse_elapsed_us = reuse_us,
        .no_reuse_last_index = no_reuse_last_index,
        .no_reuse_failures = failures,
        .no_reuse_elapsed_us = baseline_us / 1000,
    });
}
