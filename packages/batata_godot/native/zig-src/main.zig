//! Fixed raw GDExtension adapter for Batata's first Godot target.

const std = @import("std");
const build_options = @import("build_options");
const term_runtime = @import("term_runtime");
const godot = @import("godot.zig");

const class_name_z = build_options.class_name ++ "\x00";
const base_class_name_z = build_options.base_class_name ++ "\x00";

var api: godot.Api = undefined;
var library: godot.ClassLibraryPtr = null;
var class_name_storage: [8]u8 align(8) = undefined;
var base_class_name_storage: [8]u8 align(8) = undefined;
var class_registered = false;

fn initialize(userdata: ?*anyopaque, level: godot.InitializationLevel) callconv(.c) void {
    _ = userdata;
    if (level != build_options.initialization_level or class_registered) return;

    api.string_name_new_with_latin1_chars(&class_name_storage, @ptrCast(class_name_z.ptr), 1);
    api.string_name_new_with_latin1_chars(&base_class_name_storage, @ptrCast(base_class_name_z.ptr), 1);

    const creation_info = godot.ClassCreationInfo5{
        .is_virtual = 1,
        .is_abstract = 1,
        .is_exposed = 1,
        .is_runtime = 0,
        .icon_path = null,
        .set_func = null,
        .get_func = null,
        .get_property_list_func = null,
        .free_property_list_func = null,
        .property_can_revert_func = null,
        .property_get_revert_func = null,
        .validate_property_func = null,
        .notification_func = null,
        .to_string_func = null,
        .reference_func = null,
        .unreference_func = null,
        .create_instance_func = null,
        .free_instance_func = null,
        .recreate_instance_func = null,
        .get_virtual_func = null,
        .get_virtual_call_data_func = null,
        .call_virtual_with_data_func = null,
        .class_userdata = null,
    };

    api.classdb_register_extension_class5(
        library,
        &class_name_storage,
        &base_class_name_storage,
        &creation_info,
    );
    class_registered = true;
}

fn deinitialize(userdata: ?*anyopaque, level: godot.InitializationLevel) callconv(.c) void {
    _ = userdata;
    if (level != build_options.initialization_level or !class_registered) return;
    api.classdb_unregister_extension_class(library, &class_name_storage);
    class_registered = false;
}

pub fn extensionEntry(
    get_proc_address: godot.GetProcAddress,
    class_library: godot.ClassLibraryPtr,
    initialization: *godot.Initialization,
) callconv(.c) godot.Bool {
    if (class_library == null) return 0;
    api = godot.Api.resolve(get_proc_address) orelse return 0;
    library = class_library;

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

    if (build_options.class_name.len == 0 or build_options.base_class_name.len == 0) {
        @compileError("Batata.Godot class and base class names must not be empty");
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
