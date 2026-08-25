//! Closed Objective-C ABI used by the Batata AppKit adapter.
//!
//! Every `objc_msgSend` cast is kept next to its exact signature. New
//! signatures require an ABI fixture; there is no untyped dispatcher.

const builtin = @import("builtin");

pub const Id = ?*anyopaque;
pub const Class = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Bool = i8;
pub const Integer = isize;
pub const UInteger = usize;
pub const CGFloat = f64;

pub const Point = extern struct {
    x: CGFloat,
    y: CGFloat,
};

pub const Size = extern struct {
    width: CGFloat,
    height: CGFloat,
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,
};

pub extern fn objc_getClass(name: [*:0]const u8) Class;
pub extern fn sel_registerName(name: [*:0]const u8) Sel;
pub extern fn objc_retain(value: Id) Id;
pub extern fn objc_release(value: Id) void;
pub extern fn objc_autoreleasePoolPush() ?*anyopaque;
pub extern fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
pub extern fn pthread_main_np() c_int;
pub extern fn objc_allocateClassPair(superclass: Class, name: [*:0]const u8, extra_bytes: usize) Class;
pub extern fn objc_registerClassPair(class: Class) void;
pub extern fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
pub extern fn class_addProtocol(class: Class, protocol: ?*anyopaque) Bool;
pub extern fn class_addMethod(class: Class, selector: Sel, implementation: *const anyopaque, types: [*:0]const u8) Bool;

pub inline fn sendId0(receiver: Id, selector: Sel) Id {
    return @extern(*const fn (Id, Sel) callconv(.c) Id, .{ .name = "objc_msgSend" })(receiver, selector);
}

pub inline fn sendIdCString(receiver: Id, selector: Sel, value: [*:0]const u8) Id {
    return @extern(*const fn (Id, Sel, [*:0]const u8) callconv(.c) Id, .{ .name = "objc_msgSend" })(receiver, selector, value);
}

pub inline fn sendUSize0(receiver: Id, selector: Sel) usize {
    return @extern(*const fn (Id, Sel) callconv(.c) usize, .{ .name = "objc_msgSend" })(receiver, selector);
}

pub inline fn sendVoid0(receiver: Id, selector: Sel) void {
    @extern(*const fn (Id, Sel) callconv(.c) void, .{ .name = "objc_msgSend" })(receiver, selector);
}

pub inline fn sendVoidId(receiver: Id, selector: Sel, value: Id) void {
    @extern(*const fn (Id, Sel, Id) callconv(.c) void, .{ .name = "objc_msgSend" })(receiver, selector, value);
}

pub inline fn sendIdId(receiver: Id, selector: Sel, value: Id) Id {
    return @extern(*const fn (Id, Sel, Id) callconv(.c) Id, .{ .name = "objc_msgSend" })(receiver, selector, value);
}

pub inline fn sendBoolId(receiver: Id, selector: Sel, value: Id) Bool {
    return @extern(*const fn (Id, Sel, Id) callconv(.c) Bool, .{ .name = "objc_msgSend" })(receiver, selector, value);
}

pub inline fn sendBoolInteger(receiver: Id, selector: Sel, value: Integer) Bool {
    return @extern(*const fn (Id, Sel, Integer) callconv(.c) Bool, .{ .name = "objc_msgSend" })(receiver, selector, value);
}

pub inline fn sendVoidBool(receiver: Id, selector: Sel, value: Bool) void {
    @extern(*const fn (Id, Sel, Bool) callconv(.c) void, .{ .name = "objc_msgSend" })(receiver, selector, value);
}

pub inline fn sendVoidRect(receiver: Id, selector: Sel, value: Rect) void {
    @extern(*const fn (Id, Sel, Rect) callconv(.c) void, .{ .name = "objc_msgSend" })(receiver, selector, value);
}

pub inline fn sendIdRectUSizeUSizeBool(
    receiver: Id,
    selector: Sel,
    rect: Rect,
    style: UInteger,
    backing: UInteger,
    defer_creation: Bool,
) Id {
    if (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64) {
        @compileError("Batata Objective-C supports only arm64 and x86_64 macOS ABIs");
    }
    return @extern(*const fn (Id, Sel, Rect, UInteger, UInteger, Bool) callconv(.c) Id, .{ .name = "objc_msgSend" })(receiver, selector, rect, style, backing, defer_creation);
}

pub inline fn sendIdRect(receiver: Id, selector: Sel, rect: Rect) Id {
    return @extern(*const fn (Id, Sel, Rect) callconv(.c) Id, .{ .name = "objc_msgSend" })(receiver, selector, rect);
}

pub inline fn sendIdIdIdSel(receiver: Id, selector: Sel, first: Id, second: Id, third: Sel) Id {
    return @extern(*const fn (Id, Sel, Id, Id, Sel) callconv(.c) Id, .{ .name = "objc_msgSend" })(receiver, selector, first, second, third);
}

pub inline fn sendIdIdSelId(receiver: Id, selector: Sel, first: Id, second: Sel, third: Id) Id {
    return @extern(*const fn (Id, Sel, Id, Sel, Id) callconv(.c) Id, .{ .name = "objc_msgSend" })(receiver, selector, first, second, third);
}

comptime {
    if (@sizeOf(Point) != 16 or @alignOf(Point) != 8) @compileError("unexpected NSPoint ABI");
    if (@sizeOf(Size) != 16 or @alignOf(Size) != 8) @compileError("unexpected NSSize ABI");
    if (@sizeOf(Rect) != 32 or @alignOf(Rect) != 8) @compileError("unexpected NSRect ABI");
}
