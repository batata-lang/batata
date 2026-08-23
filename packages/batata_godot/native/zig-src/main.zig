//! Fixed raw GDExtension adapter for Batata's first Godot target.

const std = @import("std");
const build_options = @import("build_options");
const term_runtime = @import("term_runtime");

const GDExtensionBool = u8;
const GDExtensionInitializationLevel = c_int;
const GDExtensionInterfaceFunctionPtr = ?*const fn () callconv(.c) void;
const GDExtensionInterfaceGetProcAddress = ?*const fn ([*:0]const u8) callconv(.c) GDExtensionInterfaceFunctionPtr;
const GDExtensionClassLibraryPtr = ?*anyopaque;
const GDExtensionInitializationCallback = *const fn (?*anyopaque, GDExtensionInitializationLevel) callconv(.c) void;

const GDExtensionInitialization = extern struct {
    minimum_initialization_level: GDExtensionInitializationLevel,
    userdata: ?*anyopaque,
    initialize: GDExtensionInitializationCallback,
    deinitialize: GDExtensionInitializationCallback,
};

fn initialize(userdata: ?*anyopaque, level: GDExtensionInitializationLevel) callconv(.c) void {
    _ = userdata;
    _ = level;
}

fn deinitialize(userdata: ?*anyopaque, level: GDExtensionInitializationLevel) callconv(.c) void {
    _ = userdata;
    _ = level;
}

pub fn extensionEntry(
    get_proc_address: GDExtensionInterfaceGetProcAddress,
    library: GDExtensionClassLibraryPtr,
    initialization: *GDExtensionInitialization,
) callconv(.c) GDExtensionBool {
    if (get_proc_address == null or library == null) return 0;

    initialization.* = .{
        .minimum_initialization_level = build_options.initialization_level,
        .userdata = null,
        .initialize = &initialize,
        .deinitialize = &deinitialize,
    };
    return 1;
}

fn symbol(comptime declaration_name: []const u8) ?[]const u8 {
    return if (std.mem.eql(u8, declaration_name, "extensionEntry"))
        build_options.entry_symbol
    else
        null;
}

fn validate() void {
    if (build_options.initialization_level > 3) {
        @compileError("Batata.Godot initialization level must be in 0...3");
    }

    if (build_options.entry_symbol.len == 0) {
        @compileError("Batata.Godot entry symbol must not be empty");
    }
}

const exports = term_runtime.Extension(.{
    .namespace = @This(),
    .symbol = symbol,
    .validate = validate,
});

comptime {
    _ = exports;
}
