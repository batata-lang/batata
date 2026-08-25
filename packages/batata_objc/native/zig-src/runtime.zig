//! Fixed Objective-C ownership boundary for Batata.

const std = @import("std");
pub const abi = @import("abi.zig");

const handle_cap = 256;
const pool_cap = 64;
const index_bits = 16;
const index_mask: u64 = (1 << index_bits) - 1;

pub const Status = enum(i32) {
    ok = 0,
    invalid = -1,
    stale = -2,
    wrong_thread = -3,
    full = -4,
};

pub const Ownership = enum(u8) {
    retained,
    borrowed,
};

pub const Invoke = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

pub const ExceptionResult = extern struct {
    status: Status,
    value: ?*anyopaque,
    name: ?[*:0]const u8,
    reason: ?[*:0]const u8,
};

extern fn batata_objc_exception_fence(
    invoke: Invoke,
    context: ?*anyopaque,
    result: *?*anyopaque,
    name: *?[*:0]const u8,
    reason: *?[*:0]const u8,
) callconv(.c) i32;

const Entry = struct {
    object: abi.Id = null,
    generation: u64 = 1,
    occupied: bool = false,
    main_thread_only: bool = false,
};

const PoolEntry = struct {
    pool: ?*anyopaque = null,
    generation: u64 = 1,
    owner: std.Thread.Id = undefined,
    occupied: bool = false,
};

const RuntimeMutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *RuntimeMutex) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *RuntimeMutex) void {
        self.state.unlock();
    }
};

var handle_lock: RuntimeMutex = .{};
var handles: [handle_cap]Entry = [_]Entry{.{}} ** handle_cap;
var pool_lock: RuntimeMutex = .{};
var pools: [pool_cap]PoolEntry = [_]PoolEntry{.{}} ** pool_cap;

fn pack(index: usize, generation: u64) u64 {
    return (generation << index_bits) | @as(u64, @intCast(index + 1));
}

fn unpack(handle: u64) ?struct { index: usize, generation: u64 } {
    const encoded_index = handle & index_mask;
    if (encoded_index == 0 or encoded_index > handle_cap) return null;
    return .{
        .index = @intCast(encoded_index - 1),
        .generation = handle >> index_bits,
    };
}

pub export fn batata_objc_is_main_thread() callconv(.c) i32 {
    return if (abi.pthread_main_np() == 1) 1 else 0;
}

pub export fn batata_objc_pool_push() callconv(.c) u64 {
    const pool = abi.objc_autoreleasePoolPush();
    if (pool == null) return 0;

    pool_lock.lock();
    defer pool_lock.unlock();

    for (&pools, 0..) |*entry, index| {
        if (!entry.occupied) {
            entry.pool = pool;
            entry.owner = std.Thread.getCurrentId();
            entry.occupied = true;
            return pack(index, entry.generation);
        }
    }

    abi.objc_autoreleasePoolPop(pool);
    return 0;
}

pub export fn batata_objc_pool_pop(handle: u64) callconv(.c) Status {
    const decoded = unpack(handle) orelse return .invalid;
    if (decoded.index >= pool_cap) return .invalid;

    pool_lock.lock();
    defer pool_lock.unlock();

    const entry = &pools[decoded.index];
    if (!entry.occupied or entry.generation != decoded.generation) return .stale;
    if (entry.owner != std.Thread.getCurrentId()) return .wrong_thread;

    abi.objc_autoreleasePoolPop(entry.pool);
    entry.pool = null;
    entry.occupied = false;
    entry.generation +%= 1;
    if (entry.generation == 0) entry.generation = 1;
    return .ok;
}

/// Adopts a +1 value or roots a borrowed +0 value and returns a generation
/// checked handle. Zero means registry exhaustion or a null object.
pub export fn batata_objc_handle_create(
    object: abi.Id,
    ownership: Ownership,
    main_thread_only: bool,
) callconv(.c) u64 {
    if (object == null) return 0;
    if (main_thread_only and abi.pthread_main_np() != 1) return 0;

    handle_lock.lock();
    defer handle_lock.unlock();

    for (&handles, 0..) |*entry, index| {
        if (!entry.occupied) {
            if (ownership == .borrowed) _ = abi.objc_retain(object);
            entry.object = object;
            entry.occupied = true;
            entry.main_thread_only = main_thread_only;
            return pack(index, entry.generation);
        }
    }
    return 0;
}

pub export fn batata_objc_handle_resolve(handle: u64, output: *abi.Id) callconv(.c) Status {
    const decoded = unpack(handle) orelse return .invalid;

    handle_lock.lock();
    defer handle_lock.unlock();

    const entry = &handles[decoded.index];
    if (!entry.occupied or entry.generation != decoded.generation) return .stale;
    if (entry.main_thread_only and abi.pthread_main_np() != 1) return .wrong_thread;
    output.* = entry.object;
    return .ok;
}

pub export fn batata_objc_handle_destroy(handle: u64) callconv(.c) Status {
    const decoded = unpack(handle) orelse return .invalid;

    handle_lock.lock();
    defer handle_lock.unlock();

    const entry = &handles[decoded.index];
    if (!entry.occupied or entry.generation != decoded.generation) return .stale;
    if (entry.main_thread_only and abi.pthread_main_np() != 1) return .wrong_thread;

    const object = entry.object;
    entry.object = null;
    entry.occupied = false;
    entry.main_thread_only = false;
    entry.generation +%= 1;
    if (entry.generation == 0) entry.generation = 1;
    abi.objc_release(object);
    return .ok;
}

/// Runs a closed native invocation under an Objective-C `@try/@catch` fence.
/// Exception strings are borrowed from the active autorelease scope and must
/// be copied before that scope is popped.
pub export fn batata_objc_invoke_fenced(
    invoke: Invoke,
    context: ?*anyopaque,
) callconv(.c) ExceptionResult {
    var value: ?*anyopaque = null;
    var name: ?[*:0]const u8 = null;
    var reason: ?[*:0]const u8 = null;
    const status = batata_objc_exception_fence(invoke, context, &value, &name, &reason);
    return .{
        .status = if (status == 0) .ok else .invalid,
        .value = value,
        .name = name,
        .reason = reason,
    };
}

fn autoreleasedString(value: [*:0]const u8) abi.Id {
    const class = abi.objc_getClass("NSString");
    return abi.sendIdCString(class, abi.sel_registerName("stringWithUTF8String:"), value);
}

test "Foundation call validates the typed object ABI" {
    try std.testing.expectEqual(@as(i32, 1), batata_objc_is_main_thread());
    const pool = batata_objc_pool_push();
    defer _ = batata_objc_pool_pop(pool);

    const string = autoreleasedString("batata");
    try std.testing.expect(string != null);
    try std.testing.expectEqual(@as(usize, 6), abi.sendUSize0(string, abi.sel_registerName("length")));
}

test "owned handles reject stale generations" {
    const pool = batata_objc_pool_push();
    defer _ = batata_objc_pool_pop(pool);

    const string = autoreleasedString("rooted");
    const handle = batata_objc_handle_create(string, .borrowed, false);
    try std.testing.expect(handle != 0);

    var resolved: abi.Id = null;
    try std.testing.expectEqual(Status.ok, batata_objc_handle_resolve(handle, &resolved));
    try std.testing.expectEqual(string, resolved);
    try std.testing.expectEqual(Status.ok, batata_objc_handle_destroy(handle));
    try std.testing.expectEqual(Status.stale, batata_objc_handle_resolve(handle, &resolved));
    try std.testing.expectEqual(Status.stale, batata_objc_handle_destroy(handle));
}

test "NSRect layout matches the macOS Objective-C ABI" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(abi.Rect));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(abi.Rect));
}

const WrongThreadPoolProbe = struct {
    handle: u64,
    status: Status = .invalid,

    fn run(self: *WrongThreadPoolProbe) void {
        self.status = batata_objc_pool_pop(self.handle);
    }
};

test "autorelease pools reject cross-thread and repeated pop" {
    const pool = batata_objc_pool_push();
    try std.testing.expect(pool != 0);

    var probe = WrongThreadPoolProbe{ .handle = pool };
    const thread = try std.Thread.spawn(.{}, WrongThreadPoolProbe.run, .{&probe});
    thread.join();

    try std.testing.expectEqual(Status.wrong_thread, probe.status);
    try std.testing.expectEqual(Status.ok, batata_objc_pool_pop(pool));
    try std.testing.expectEqual(Status.stale, batata_objc_pool_pop(pool));
}

extern fn batata_objc_exception_probe(context: ?*anyopaque) callconv(.c) ?*anyopaque;

test "Objective-C exceptions stop at the C ABI fence" {
    const pool = batata_objc_pool_push();
    defer _ = batata_objc_pool_pop(pool);

    const result = batata_objc_invoke_fenced(batata_objc_exception_probe, null);
    try std.testing.expectEqual(Status.invalid, result.status);
    try std.testing.expect(result.value == null);
    try std.testing.expectEqualStrings("BatataProbe", std.mem.span(result.name.?));
    try std.testing.expectEqualStrings("closed Objective-C exception", std.mem.span(result.reason.?));
}
