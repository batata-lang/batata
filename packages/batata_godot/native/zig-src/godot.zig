//! Minimal Godot 4.6 GDExtension ABI used by the fixed Batata adapter.
//!
//! This is deliberately a closed surface copied from the pinned
//! `gdextension_interface.h`. Additions must be accompanied by a real Godot
//! smoke test; unsupported interface functions are not resolved speculatively.

pub const Bool = u8;
pub const Int = i64;
pub const InitializationLevel = c_int;
pub const InterfaceFunctionPtr = ?*const fn () callconv(.c) void;
pub const GetProcAddress = ?*const fn ([*:0]const u8) callconv(.c) InterfaceFunctionPtr;
pub const ClassLibraryPtr = ?*anyopaque;
pub const ObjectPtr = ?*anyopaque;
pub const ClassInstancePtr = ?*anyopaque;
pub const StringNamePtr = *anyopaque;
pub const ConstStringNamePtr = *const anyopaque;

pub const InitializationCallback = *const fn (?*anyopaque, InitializationLevel) callconv(.c) void;

pub const Initialization = extern struct {
    minimum_initialization_level: InitializationLevel,
    userdata: ?*anyopaque,
    initialize: InitializationCallback,
    deinitialize: InitializationCallback,
};

pub const ClassCreateInstance = *const fn (?*anyopaque, Bool) callconv(.c) ObjectPtr;
pub const ClassFreeInstance = *const fn (?*anyopaque, ClassInstancePtr) callconv(.c) void;

/// ABI-equivalent to `GDExtensionClassCreationInfo5` in Godot 4.6.
pub const ClassCreationInfo5 = extern struct {
    is_virtual: Bool,
    is_abstract: Bool,
    is_exposed: Bool,
    is_runtime: Bool,
    icon_path: ?*const anyopaque,
    set_func: ?*const anyopaque,
    get_func: ?*const anyopaque,
    get_property_list_func: ?*const anyopaque,
    free_property_list_func: ?*const anyopaque,
    property_can_revert_func: ?*const anyopaque,
    property_get_revert_func: ?*const anyopaque,
    validate_property_func: ?*const anyopaque,
    notification_func: ?*const anyopaque,
    to_string_func: ?*const anyopaque,
    reference_func: ?*const anyopaque,
    unreference_func: ?*const anyopaque,
    create_instance_func: ?ClassCreateInstance,
    free_instance_func: ?ClassFreeInstance,
    recreate_instance_func: ?*const anyopaque,
    get_virtual_func: ?*const anyopaque,
    get_virtual_call_data_func: ?*const anyopaque,
    call_virtual_with_data_func: ?*const anyopaque,
    class_userdata: ?*anyopaque,
};

pub const StringNameNewWithLatin1Chars = *const fn (StringNamePtr, [*:0]const u8, Bool) callconv(.c) void;
pub const ClassdbRegisterExtensionClass5 = *const fn (ClassLibraryPtr, ConstStringNamePtr, ConstStringNamePtr, *const ClassCreationInfo5) callconv(.c) void;
pub const ClassdbUnregisterExtensionClass = *const fn (ClassLibraryPtr, ConstStringNamePtr) callconv(.c) void;

pub const Api = struct {
    string_name_new_with_latin1_chars: StringNameNewWithLatin1Chars,
    classdb_register_extension_class5: ClassdbRegisterExtensionClass5,
    classdb_unregister_extension_class: ClassdbUnregisterExtensionClass,

    pub fn resolve(get_proc_address: GetProcAddress) ?Api {
        const get = get_proc_address orelse return null;
        return .{
            .string_name_new_with_latin1_chars = resolveOne(StringNameNewWithLatin1Chars, get, "string_name_new_with_latin1_chars") orelse return null,
            .classdb_register_extension_class5 = resolveOne(ClassdbRegisterExtensionClass5, get, "classdb_register_extension_class5") orelse return null,
            .classdb_unregister_extension_class = resolveOne(ClassdbUnregisterExtensionClass, get, "classdb_unregister_extension_class") orelse return null,
        };
    }
};

fn resolveOne(comptime T: type, get: *const fn ([*:0]const u8) callconv(.c) InterfaceFunctionPtr, comptime name: [:0]const u8) ?T {
    const raw = get(name.ptr) orelse return null;
    return @ptrCast(raw);
}
