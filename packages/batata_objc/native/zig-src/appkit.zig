//! Closed AppKit vertical slice: application delegate, window, label, button,
//! target-action callback and deterministic teardown.

const std = @import("std");
const options = @import("build_options");
const objc_runtime = @import("objc_runtime");
const abi = objc_runtime.abi;
const term_runtime = @import("term_runtime");

const MainThread = struct { seal: void = {} };

var application: abi.Id = null;
var delegate_handle: u64 = 0;
var window_handle: u64 = 0;
var label: abi.Id = null;
var button: abi.Id = null;
var runtime_handle: i64 = 0;
var callback_failed = false;
var should_terminate = false;
var smoke_finished: std.atomic.Value(bool) = .init(false);

fn cString(comptime value: []const u8) [*:0]const u8 {
    return @ptrCast((value ++ "\x00").ptr);
}

fn selector(comptime name: []const u8) abi.Sel {
    return abi.sel_registerName(cString(name));
}

fn acquireMainThread() ?MainThread {
    return if (objc_runtime.batata_objc_is_main_thread() == 1) .{} else null;
}

fn rect(values: [4]f64) abi.Rect {
    return .{
        .origin = .{ .x = values[0], .y = values[1] },
        .size = .{ .width = values[2], .height = values[3] },
    };
}

fn nsString(comptime value: []const u8) abi.Id {
    return abi.sendIdCString(abi.objc_getClass("NSString"), selector("stringWithUTF8String:"), cString(value));
}

fn invokeBatata0(comptime symbol: []const u8) ?i64 {
    if (runtime_handle <= 0) return null;
    if (term_runtime.ex_term_runtime_enter(runtime_handle) != 0) return null;
    defer _ = term_runtime.ex_term_runtime_leave();
    if (term_runtime.ex_term_process_table_reset(256) != 1) return null;
    return @extern(*const fn () callconv(.c) i64, .{ .name = symbol })();
}

fn reportException(result: objc_runtime.ExceptionResult) void {
    callback_failed = true;
    std.debug.print("E_OBJC_EXCEPTION name={s} reason={s}\n", .{
        if (result.name) |name| std.mem.span(name) else "unknown",
        if (result.reason) |reason| std.mem.span(reason) else "unknown",
    });
    if (application != null) {
        if (options.smoke) finishSmokeProcess() else abi.sendVoidId(application, selector("terminate:"), null);
    }
}

fn finishSmokeProcess() noreturn {
    smoke_finished.store(true, .release);
    if (!callback_failed) std.debug.print("BATATA_OBJC_CLEAN_EXIT\n", .{});
    std.process.exit(if (callback_failed) 23 else 0);
}

fn didFinishBody(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = acquireMainThread() orelse {
        callback_failed = true;
        std.debug.print("E_OBJC_MAIN_THREAD_REQUIRED callback=applicationDidFinishLaunching:\n", .{});
        return null;
    };
    _ = invokeBatata0(options.did_finish_symbol) orelse {
        callback_failed = true;
        std.debug.print("E_OBJC_CALLBACK_NOT_ROOTED callback=did_finish_launching\n", .{});
        return null;
    };
    std.debug.print("BATATA_OBJC_CALLBACK did_finish_launching\n", .{});

    const window_alloc = abi.sendId0(abi.objc_getClass("NSWindow"), selector("alloc"));
    const window = abi.sendIdRectUSizeUSizeBool(
        window_alloc,
        selector("initWithContentRect:styleMask:backing:defer:"),
        rect(.{ options.window_x, options.window_y, options.window_width, options.window_height }),
        15,
        2,
        0,
    );
    if (window == null) {
        callback_failed = true;
        std.debug.print("E_OBJC_HANDLE_STALE object=NSWindow\n", .{});
        return null;
    }
    abi.sendVoidBool(window, selector("setReleasedWhenClosed:"), 0);
    abi.sendVoidId(window, selector("setTitle:"), nsString(options.window_title));
    window_handle = objc_runtime.batata_objc_handle_create(window, .retained, true);
    if (window_handle == 0) {
        callback_failed = true;
        abi.objc_release(window);
        return null;
    }

    const content = abi.sendId0(window, selector("contentView"));
    label = abi.sendIdId(abi.objc_getClass("NSTextField"), selector("labelWithString:"), nsString(options.label_text));
    button = abi.sendIdIdIdSel(
        abi.objc_getClass("NSButton"),
        selector("buttonWithTitle:target:action:"),
        nsString(options.button_title),
        resolveHandle(delegate_handle),
        selector("batataButtonPressed:"),
    );
    if (content == null or label == null or button == null) {
        callback_failed = true;
        std.debug.print("E_OBJC_HANDLE_STALE object=AppKitControl\n", .{});
        return null;
    }
    abi.sendVoidRect(label, selector("setFrame:"), rect(.{ options.label_x, options.label_y, options.label_width, options.label_height }));
    abi.sendVoidRect(button, selector("setFrame:"), rect(.{ options.button_x, options.button_y, options.button_width, options.button_height }));
    abi.sendVoidId(content, selector("addSubview:"), label);
    abi.sendVoidId(content, selector("addSubview:"), button);
    abi.sendVoidId(window, selector("makeKeyAndOrderFront:"), null);
    abi.sendVoidBool(application, selector("activateIgnoringOtherApps:"), 1);

    if (options.smoke) {
        if (objc_runtime.batata_objc_dispatch_main(null, smokeAction) != .ok) {
            callback_failed = true;
            std.debug.print("E_OBJC_MAIN_QUEUE_UNAVAILABLE\n", .{});
        }
    }
    return null;
}

fn smokeAction(_: ?*anyopaque) callconv(.c) void {
    if (acquireMainThread() == null) {
        callback_failed = true;
        std.debug.print("E_OBJC_MAIN_THREAD_REQUIRED callback=smokeAction\n", .{});
        finishSmokeProcess();
    }
    std.debug.print("BATATA_OBJC_MAIN_QUEUE\n", .{});
    abi.sendVoidId(button, selector("performClick:"), null);
    const result = abi.sendBoolId(resolveHandle(delegate_handle), selector("applicationShouldTerminateAfterLastWindowClosed:"), application);
    if (result == 0) {
        callback_failed = true;
        std.debug.print("E_OBJC_TERMINATION_REJECTED\n", .{});
    }
    finishSmokeProcess();
}

fn smokeWatchdog() void {
    _ = @extern(*const fn (c_uint) callconv(.c) c_uint, .{ .name = "sleep" })(15);
    if (!smoke_finished.load(.acquire)) {
        std.debug.print("E_OBJC_APPKIT_SMOKE_TIMEOUT seconds=15\n", .{});
        std.process.exit(24);
    }
}

fn didFinish(_: abi.Id, _: abi.Sel, _: abi.Id) callconv(.c) void {
    const result = objc_runtime.batata_objc_invoke_fenced(didFinishBody, null);
    if (result.status != .ok) reportException(result);
}

fn buttonBody(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = acquireMainThread() orelse {
        callback_failed = true;
        return null;
    };
    _ = invokeBatata0(options.button_symbol) orelse {
        callback_failed = true;
        return null;
    };
    abi.sendVoidId(label, selector("setStringValue:"), nsString("Batata callback complete"));
    std.debug.print("BATATA_OBJC_CALLBACK button_pressed\n", .{});
    return null;
}

fn buttonPressed(_: abi.Id, _: abi.Sel, _: abi.Id) callconv(.c) void {
    const result = objc_runtime.batata_objc_invoke_fenced(buttonBody, null);
    if (result.status != .ok) reportException(result);
}

fn shouldTerminateBody(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = acquireMainThread() orelse {
        callback_failed = true;
        return null;
    };
    const word = invokeBatata0(options.should_terminate_symbol) orelse {
        callback_failed = true;
        return null;
    };
    should_terminate = word == options.true_word;
    std.debug.print("BATATA_OBJC_CALLBACK should_terminate={any}\n", .{should_terminate});
    return null;
}

fn applicationShouldTerminate(_: abi.Id, _: abi.Sel, _: abi.Id) callconv(.c) abi.Bool {
    should_terminate = false;
    const result = objc_runtime.batata_objc_invoke_fenced(shouldTerminateBody, null);
    if (result.status != .ok) reportException(result);
    return if (should_terminate) 1 else 0;
}

fn resolveHandle(handle: u64) abi.Id {
    var object: abi.Id = null;
    return if (objc_runtime.batata_objc_handle_resolve(handle, &object) == .ok) object else null;
}

fn createDelegate(_: MainThread) ?abi.Id {
    const class_name = "BatataAppDelegate";
    if (abi.objc_getClass(class_name)) |registered| {
        return abi.sendId0(abi.sendId0(registered, selector("alloc")), selector("init"));
    }

    const superclass = abi.objc_getClass("NSObject") orelse return null;
    const class = abi.objc_allocateClassPair(superclass, class_name, 0) orelse {
        std.debug.print("E_OBJC_DELEGATE_REGISTRATION stage=allocate\n", .{});
        return null;
    };
    if (abi.class_addMethod(class, selector("applicationDidFinishLaunching:"), @ptrCast(&didFinish), "v@:@") == 0) {
        std.debug.print("E_OBJC_DELEGATE_REGISTRATION stage=did_finish_method\n", .{});
        return null;
    }
    if (abi.class_addMethod(class, selector("applicationShouldTerminateAfterLastWindowClosed:"), @ptrCast(&applicationShouldTerminate), "B@:@") == 0) {
        std.debug.print("E_OBJC_DELEGATE_REGISTRATION stage=termination_method\n", .{});
        return null;
    }
    if (abi.class_addMethod(class, selector("batataButtonPressed:"), @ptrCast(&buttonPressed), "v@:@") == 0) {
        std.debug.print("E_OBJC_DELEGATE_REGISTRATION stage=button_method\n", .{});
        return null;
    }
    const protocol = abi.batata_objc_ns_application_delegate_protocol() orelse {
        std.debug.print("E_OBJC_DELEGATE_REGISTRATION stage=protocol_lookup\n", .{});
        return null;
    };
    if (abi.class_addProtocol(class, protocol) == 0) {
        std.debug.print("E_OBJC_DELEGATE_REGISTRATION stage=protocol_attach\n", .{});
        return null;
    }
    abi.objc_registerClassPair(class);

    return abi.sendId0(abi.sendId0(class, selector("alloc")), selector("init"));
}

pub fn main() u8 {
    const mt = acquireMainThread() orelse {
        std.debug.print("E_OBJC_MAIN_THREAD_REQUIRED phase=main\n", .{});
        return 17;
    };
    const pool = objc_runtime.batata_objc_pool_push();
    if (pool == 0) return 18;
    defer _ = objc_runtime.batata_objc_pool_pop(pool);

    runtime_handle = term_runtime.ex_term_runtime_create();
    if (runtime_handle <= 0) return 19;
    defer _ = term_runtime.ex_term_runtime_destroy(runtime_handle);

    application = abi.sendId0(abi.objc_getClass("NSApplication"), selector("sharedApplication"));
    if (application == null) return 22;

    const delegate = createDelegate(mt) orelse return 20;
    delegate_handle = objc_runtime.batata_objc_handle_create(delegate, .retained, true);
    if (delegate_handle == 0) {
        abi.objc_release(delegate);
        return 21;
    }
    defer _ = objc_runtime.batata_objc_handle_destroy(delegate_handle);

    _ = abi.sendBoolInteger(application, selector("setActivationPolicy:"), 0);
    abi.sendVoidId(application, selector("setDelegate:"), delegate);
    if (options.smoke) {
        const watchdog = std.Thread.spawn(.{}, smokeWatchdog, .{}) catch {
            std.debug.print("E_OBJC_APPKIT_SMOKE_WATCHDOG_UNAVAILABLE\n", .{});
            return 24;
        };
        watchdog.detach();
    }
    abi.sendVoid0(application, selector("run"));
    smoke_finished.store(true, .release);
    abi.sendVoidId(application, selector("setDelegate:"), null);

    if (window_handle != 0) {
        _ = objc_runtime.batata_objc_handle_destroy(window_handle);
        window_handle = 0;
    }
    label = null;
    button = null;
    std.debug.print("BATATA_OBJC_CLEAN_EXIT\n", .{});
    return if (callback_failed) 23 else 0;
}
