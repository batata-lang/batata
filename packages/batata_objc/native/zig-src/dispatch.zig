//! Closed main-queue operation. Arbitrary queues and signatures are absent.

const abi = @import("abi.zig");

pub const Context = ?*anyopaque;
pub const Callback = *const fn (Context) callconv(.c) void;

extern var _dispatch_main_q: anyopaque;
extern fn dispatch_async_f(queue: ?*anyopaque, context: Context, work: Callback) void;

pub fn mainAsync(context: Context, callback: Callback) bool {
    dispatch_async_f(&_dispatch_main_q, context, callback);
    return true;
}

pub fn requireMainThread() bool {
    return abi.pthread_main_np() == 1;
}
