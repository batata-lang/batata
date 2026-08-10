const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const runtime = @import("runtime");

// #50 stage 1 benchmark: a long-running runtime creating short-lived actors.
// With slot recycling, a small process table sustains an unbounded number of
// spawn+complete cycles (process_count peaks at the concurrency, not the
// cumulative count); without recycling, spawn fails once the table fills.
//
// Run: zig run -O ReleaseFast --dep runtime \
//   -Mroot=bench/process_reuse.zig -Mruntime=native/term_runtime.zig -lc

const iterations: usize = 1_000_000;
const cap: i64 = 8;

fn now_ns() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn short_lived(pid: i64) callconv(.c) i64 {
    return pid;
}

pub fn main() void {
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
    const start = now_ns();
    while (spawned < iterations) : (spawned += 1) {
        const pid = runtime.ex_term_spawn(1);
        if (pid == 1) break; // nil: table full (should not happen with reuse)
        const runnable = runtime.ex_term_processes_runnable();
        if (runnable > peak_runnable) peak_runnable = runnable;
        _ = runtime.ex_term_process_claim_next(1);
        _ = runtime.ex_term_process_done(pid);
    }
    const reuse_us = (now_ns() - start) / 1000;
    _ = runtime.ex_term_runtime_destroy(handle);

    // Baseline without recycling: spawn without completing. The table fills at
    // cap and every further spawn returns nil.
    const handle2 = runtime.ex_term_runtime_create();
    _ = runtime.ex_term_runtime_enter(handle2);
    _ = runtime.ex_term_process_table_reset(cap);
    var failures: usize = 0;
    const baseline_start = now_ns();
    for (0..iterations) |_| {
        if (runtime.ex_term_spawn(1) == 1) failures += 1;
    }
    const baseline_us = now_ns() - baseline_start;
    _ = runtime.ex_term_runtime_destroy(handle2);

    std.debug.print(
        \\{{"spawns": {d}, "cap": {d}, "reuse_success": {d},
        \\ "reuse_peak_runnable": {d}, "reuse_elapsed_us": {d},
        \\ "no_reuse_failures": {d}, "no_reuse_elapsed_us": {d}}}
        \\
    , .{
        iterations,
        cap,
        spawned,
        peak_runnable,
        reuse_us,
        failures,
        baseline_us / 1000,
    });
}
