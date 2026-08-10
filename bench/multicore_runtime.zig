const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});
const runtime = @import("runtime");

const actor_count = 4;
var work_iterations: usize = 30_000_000;

const Result = struct {
    elapsed_ns: u64,
    max_active: i64,
    migrations: i64,
    thread_ids: [actor_count]i64,
};

fn now_ns() u64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

fn cpu_actor(pid: i64) callconv(.c) i64 {
    var value: u64 = @bitCast(pid);
    for (0..work_iterations) |index| {
        value = value *% 6_364_136_223_846_793_005 +% @as(u64, @intCast(index)) +% 1;
    }
    std.mem.doNotOptimizeAway(value);
    return pid;
}

fn run(worker_count: i64) Result {
    const handle = runtime.ex_term_runtime_create();
    _ = runtime.ex_term_runtime_enter(handle);
    _ = runtime.ex_term_process_table_reset();
    for (1..actor_count) |_| _ = runtime.ex_term_spawn(1);

    const start = now_ns();
    _ = runtime.ex_term_worker_run(worker_count, &cpu_actor);
    const elapsed = now_ns() - start;

    var thread_ids: [actor_count]i64 = undefined;
    for (&thread_ids, 0..) |*thread_id, index| {
        const pid = (@as(i64, @intCast(index + 1)) << 3) | 1;
        thread_id.* = runtime.ex_term_process_thread_id(pid);
    }

    const result = Result{
        .elapsed_ns = elapsed,
        .max_active = runtime.ex_term_worker_max_active(),
        .migrations = runtime.ex_term_worker_migrations(),
        .thread_ids = thread_ids,
    };
    _ = runtime.ex_term_runtime_destroy(handle);
    return result;
}

pub fn main() void {
    work_iterations = 500_000;
    _ = run(2);
    work_iterations = 30_000_000;

    const one = run(1);
    const two = run(2);
    const four = run(4);
    const speedup_two = @as(f64, @floatFromInt(one.elapsed_ns)) / @as(f64, @floatFromInt(two.elapsed_ns));
    const speedup_four = @as(f64, @floatFromInt(one.elapsed_ns)) / @as(f64, @floatFromInt(four.elapsed_ns));

    std.debug.print(
        "{{\"actors\":{d},\"iterations_per_actor\":{d}," ++
            "\"one_worker_ns\":{d},\"two_worker_ns\":{d},\"four_worker_ns\":{d}," ++
            "\"two_worker_speedup\":{d:.3},\"four_worker_speedup\":{d:.3}," ++
            "\"two_worker_max_active\":{d},\"four_worker_max_active\":{d}," ++
            "\"two_worker_migrations\":{d},\"four_worker_migrations\":{d}," ++
            "\"four_worker_thread_ids\":[{d},{d},{d},{d}]}}\n",
        .{
            actor_count,
            work_iterations,
            one.elapsed_ns,
            two.elapsed_ns,
            four.elapsed_ns,
            speedup_two,
            speedup_four,
            two.max_active,
            four.max_active,
            two.migrations,
            four.migrations,
            four.thread_ids[0],
            four.thread_ids[1],
            four.thread_ids[2],
            four.thread_ids[3],
        },
    );
}
