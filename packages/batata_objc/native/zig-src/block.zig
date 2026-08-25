//! One closed Apple Block ABI shape used for `void (^)(void *)` callbacks.

const std = @import("std");

const block_has_copy_dispose: i32 = 1 << 25;
const block_has_signature: i32 = 1 << 30;

extern var _NSConcreteStackBlock: anyopaque;
extern fn _Block_copy(block: *const anyopaque) ?*anyopaque;
extern fn _Block_release(block: ?*const anyopaque) void;

pub const PayloadRetain = *const fn (?*anyopaque) callconv(.c) void;
pub const PayloadRelease = *const fn (?*anyopaque) callconv(.c) void;
pub const Invoke = *const fn (?*anyopaque) callconv(.c) void;

pub const Context = extern struct {
    payload: ?*anyopaque,
    retain: PayloadRetain,
    release: PayloadRelease,
    callback: Invoke,
};

const Descriptor = extern struct {
    reserved: usize,
    size: usize,
    copy_helper: *const fn (*Literal, *const Literal) callconv(.c) void,
    dispose_helper: *const fn (*const Literal) callconv(.c) void,
    signature: [*:0]const u8,
};

pub const Literal = extern struct {
    isa: *anyopaque,
    flags: i32,
    reserved: i32,
    invoke: *const fn (*Literal) callconv(.c) void,
    descriptor: *const Descriptor,
    context: Context,

    pub fn init(payload: ?*anyopaque, retain: PayloadRetain, release_payload: PayloadRelease, invoke: Invoke) Literal {
        return .{
            .isa = &_NSConcreteStackBlock,
            .flags = block_has_copy_dispose | block_has_signature,
            .reserved = 0,
            .invoke = &invokeLiteral,
            .descriptor = &descriptor,
            .context = .{ .payload = payload, .retain = retain, .release = release_payload, .callback = invoke },
        };
    }

    pub fn copy(self: *const Literal) ?*Literal {
        return @ptrCast(@alignCast(_Block_copy(self)));
    }

    pub fn call(self: *Literal) void {
        self.invoke(self);
    }

    pub fn release(self: *const Literal) void {
        _Block_release(self);
    }
};

fn invokeLiteral(block: *Literal) callconv(.c) void {
    block.context.callback(block.context.payload);
}

fn copyHelper(destination: *Literal, source: *const Literal) callconv(.c) void {
    destination.context = source.context;
    destination.context.retain(destination.context.payload);
}

fn disposeHelper(block: *const Literal) callconv(.c) void {
    block.context.release(block.context.payload);
}

const descriptor = Descriptor{
    .reserved = 0,
    .size = @sizeOf(Literal),
    .copy_helper = &copyHelper,
    .dispose_helper = &disposeHelper,
    .signature = "v8@?0",
};

var retain_count: usize = 0;
var release_count: usize = 0;
var invoke_count: usize = 0;

fn testRetain(_: ?*anyopaque) callconv(.c) void {
    retain_count += 1;
}

fn testRelease(_: ?*anyopaque) callconv(.c) void {
    release_count += 1;
}

fn testInvoke(_: ?*anyopaque) callconv(.c) void {
    invoke_count += 1;
}

test "Block copy and dispose close the capture lifetime" {
    retain_count = 0;
    release_count = 0;
    invoke_count = 0;
    var stack = Literal.init(null, testRetain, testRelease, testInvoke);
    const heap = stack.copy() orelse return error.BlockCopyFailed;
    try std.testing.expectEqual(@as(usize, 1), retain_count);
    heap.call();
    try std.testing.expectEqual(@as(usize, 1), invoke_count);
    heap.release();
    try std.testing.expectEqual(@as(usize, 1), release_count);
}
