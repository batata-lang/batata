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
pub const VariantPtr = ?*anyopaque;
pub const ConstVariantPtr = ?*const anyopaque;
pub const StringNamePtr = ?*anyopaque;
pub const ConstStringNamePtr = ?*const anyopaque;
pub const TypePtr = ?*anyopaque;
pub const ConstTypePtr = ?*const anyopaque;

pub const InitializationCallback = *const fn (?*anyopaque, InitializationLevel) callconv(.c) void;

pub const Initialization = extern struct {
    minimum_initialization_level: InitializationLevel,
    userdata: ?*anyopaque,
    initialize: InitializationCallback,
    deinitialize: InitializationCallback,
};

pub const ClassCreateInstance = *const fn (?*anyopaque, Bool) callconv(.c) ObjectPtr;
pub const ClassFreeInstance = *const fn (?*anyopaque, ClassInstancePtr) callconv(.c) void;
pub const ClassMethodCall = *const fn (?*anyopaque, ClassInstancePtr, ?[*]const ConstVariantPtr, Int, VariantPtr, *CallError) callconv(.c) void;
pub const ClassMethodPtrCall = *const fn (?*anyopaque, ClassInstancePtr, ?[*]const ConstTypePtr, TypePtr) callconv(.c) void;

pub const VariantType = enum(c_int) {
    nil = 0,
    bool = 1,
    int = 2,
    float = 3,
    string = 4,
    vector2 = 5,
    vector3 = 9,
    string_name = 21,
    object = 24,
};

pub const CallErrorType = enum(c_int) {
    ok = 0,
    invalid_method = 1,
    invalid_argument = 2,
    too_many_arguments = 3,
    too_few_arguments = 4,
    instance_is_null = 5,
    method_not_const = 6,
};

pub const CallError = extern struct {
    error_code: CallErrorType,
    argument: i32,
    expected: i32,
};

pub const Vector2 = extern struct { x: f32, y: f32 };
pub const Vector3 = extern struct { x: f32, y: f32, z: f32 };

pub const PropertyInfo = extern struct {
    variant_type: VariantType,
    name: StringNamePtr,
    class_name: StringNamePtr,
    hint: u32,
    hint_string: ?*anyopaque,
    usage: u32,
};

pub const ClassMethodInfo = extern struct {
    name: StringNamePtr,
    method_userdata: ?*anyopaque,
    call_func: ClassMethodCall,
    ptrcall_func: ?ClassMethodPtrCall,
    method_flags: u32,
    has_return_value: Bool,
    return_value_info: ?*PropertyInfo,
    return_value_metadata: c_int,
    argument_count: u32,
    arguments_info: ?[*]PropertyInfo,
    arguments_metadata: ?[*]c_int,
    default_argument_count: u32,
    default_arguments: ?[*]VariantPtr,
};

pub const InstanceBindingCallbacks = extern struct {
    create_callback: ?*const anyopaque,
    free_callback: ?*const anyopaque,
    reference_callback: ?*const anyopaque,
};

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

pub const MemAlloc2 = *const fn (usize, Bool) callconv(.c) ?*anyopaque;
pub const MemFree2 = *const fn (?*anyopaque, Bool) callconv(.c) void;
pub const PrintError = *const fn ([*:0]const u8, [*:0]const u8, [*:0]const u8, i32, Bool) callconv(.c) void;
pub const StringNameNewWithLatin1Chars = *const fn (StringNamePtr, [*:0]const u8, Bool) callconv(.c) void;
pub const StringNameNewWithUtf8CharsAndLen = *const fn (StringNamePtr, [*]const u8, Int) callconv(.c) void;
pub const StringNewWithUtf8Chars = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) void;
pub const StringNewWithUtf8CharsAndLen2 = *const fn (?*anyopaque, [*]const u8, Int) callconv(.c) Int;
pub const StringToUtf8Chars = *const fn (?*const anyopaque, ?[*]u8, Int) callconv(.c) Int;
pub const PtrDestructor = *const fn (TypePtr) callconv(.c) void;
pub const PtrConstructor = *const fn (TypePtr, ?[*]const ConstTypePtr) callconv(.c) void;
pub const VariantGetPtrDestructor = *const fn (VariantType) callconv(.c) ?PtrDestructor;
pub const VariantGetPtrConstructor = *const fn (VariantType, i32) callconv(.c) ?PtrConstructor;
pub const VariantGetType = *const fn (ConstVariantPtr) callconv(.c) VariantType;
pub const VariantFromTypeConstructor = *const fn (VariantPtr, TypePtr) callconv(.c) void;
pub const TypeFromVariantConstructor = *const fn (TypePtr, VariantPtr) callconv(.c) void;
pub const GetVariantFromTypeConstructor = *const fn (VariantType) callconv(.c) ?VariantFromTypeConstructor;
pub const GetVariantToTypeConstructor = *const fn (VariantType) callconv(.c) ?TypeFromVariantConstructor;
pub const VariantNewNil = *const fn (VariantPtr) callconv(.c) void;
pub const ClassdbConstructObject2 = *const fn (ConstStringNamePtr) callconv(.c) ObjectPtr;
pub const ObjectSetInstance = *const fn (ObjectPtr, ConstStringNamePtr, ClassInstancePtr) callconv(.c) void;
pub const ObjectSetInstanceBinding = *const fn (ObjectPtr, ?*anyopaque, ?*anyopaque, *const InstanceBindingCallbacks) callconv(.c) void;
pub const ObjectDestroy = *const fn (ObjectPtr) callconv(.c) void;
pub const ObjectCastTo = *const fn (?*const anyopaque, ?*anyopaque) callconv(.c) ObjectPtr;
pub const ClassdbGetClassTag = *const fn (ConstStringNamePtr) callconv(.c) ?*anyopaque;
pub const ClassdbRegisterExtensionClass5 = *const fn (ClassLibraryPtr, ConstStringNamePtr, ConstStringNamePtr, *const ClassCreationInfo5) callconv(.c) void;
pub const ClassdbRegisterExtensionClassMethod = *const fn (ClassLibraryPtr, ConstStringNamePtr, *const ClassMethodInfo) callconv(.c) void;
pub const ClassdbUnregisterExtensionClass = *const fn (ClassLibraryPtr, ConstStringNamePtr) callconv(.c) void;

pub const Api = struct {
    mem_alloc2: MemAlloc2,
    mem_free2: MemFree2,
    print_error: PrintError,
    string_name_new_with_latin1_chars: StringNameNewWithLatin1Chars,
    string_name_new_with_utf8_chars_and_len: StringNameNewWithUtf8CharsAndLen,
    string_new_with_utf8_chars: StringNewWithUtf8Chars,
    string_new_with_utf8_chars_and_len2: StringNewWithUtf8CharsAndLen2,
    string_to_utf8_chars: StringToUtf8Chars,
    string_destructor: PtrDestructor,
    string_name_destructor: PtrDestructor,
    string_from_string_name: PtrConstructor,
    variant_get_type: VariantGetType,
    variant_new_nil: VariantNewNil,
    bool_from_variant: TypeFromVariantConstructor,
    bool_to_variant: VariantFromTypeConstructor,
    int_from_variant: TypeFromVariantConstructor,
    int_to_variant: VariantFromTypeConstructor,
    float_from_variant: TypeFromVariantConstructor,
    float_to_variant: VariantFromTypeConstructor,
    string_from_variant: TypeFromVariantConstructor,
    string_to_variant: VariantFromTypeConstructor,
    string_name_from_variant: TypeFromVariantConstructor,
    string_name_to_variant: VariantFromTypeConstructor,
    vector2_from_variant: TypeFromVariantConstructor,
    vector2_to_variant: VariantFromTypeConstructor,
    vector3_from_variant: TypeFromVariantConstructor,
    vector3_to_variant: VariantFromTypeConstructor,
    classdb_construct_object2: ClassdbConstructObject2,
    object_set_instance: ObjectSetInstance,
    object_set_instance_binding: ObjectSetInstanceBinding,
    object_destroy: ObjectDestroy,
    object_cast_to: ObjectCastTo,
    classdb_get_class_tag: ClassdbGetClassTag,
    object_from_variant: TypeFromVariantConstructor,
    object_to_variant: VariantFromTypeConstructor,
    classdb_register_extension_class5: ClassdbRegisterExtensionClass5,
    classdb_register_extension_class_method: ClassdbRegisterExtensionClassMethod,
    classdb_unregister_extension_class: ClassdbUnregisterExtensionClass,

    pub fn resolve(get_proc_address: GetProcAddress) ?Api {
        const get = get_proc_address orelse return null;
        const get_from = resolveOne(GetVariantFromTypeConstructor, get, "get_variant_from_type_constructor") orelse return null;
        const get_to = resolveOne(GetVariantToTypeConstructor, get, "get_variant_to_type_constructor") orelse return null;
        const get_destructor = resolveOne(VariantGetPtrDestructor, get, "variant_get_ptr_destructor") orelse return null;
        const get_constructor = resolveOne(VariantGetPtrConstructor, get, "variant_get_ptr_constructor") orelse return null;
        return .{
            .mem_alloc2 = resolveOne(MemAlloc2, get, "mem_alloc2") orelse return null,
            .mem_free2 = resolveOne(MemFree2, get, "mem_free2") orelse return null,
            .print_error = resolveOne(PrintError, get, "print_error") orelse return null,
            .string_name_new_with_latin1_chars = resolveOne(StringNameNewWithLatin1Chars, get, "string_name_new_with_latin1_chars") orelse return null,
            .string_name_new_with_utf8_chars_and_len = resolveOne(StringNameNewWithUtf8CharsAndLen, get, "string_name_new_with_utf8_chars_and_len") orelse return null,
            .string_new_with_utf8_chars = resolveOne(StringNewWithUtf8Chars, get, "string_new_with_utf8_chars") orelse return null,
            .string_new_with_utf8_chars_and_len2 = resolveOne(StringNewWithUtf8CharsAndLen2, get, "string_new_with_utf8_chars_and_len2") orelse return null,
            .string_to_utf8_chars = resolveOne(StringToUtf8Chars, get, "string_to_utf8_chars") orelse return null,
            .string_destructor = get_destructor(.string) orelse return null,
            .string_name_destructor = get_destructor(.string_name) orelse return null,
            .string_from_string_name = get_constructor(.string, 2) orelse return null,
            .variant_get_type = resolveOne(VariantGetType, get, "variant_get_type") orelse return null,
            .variant_new_nil = resolveOne(VariantNewNil, get, "variant_new_nil") orelse return null,
            .bool_from_variant = get_to(.bool) orelse return null,
            .bool_to_variant = get_from(.bool) orelse return null,
            .int_from_variant = get_to(.int) orelse return null,
            .int_to_variant = get_from(.int) orelse return null,
            .float_from_variant = get_to(.float) orelse return null,
            .float_to_variant = get_from(.float) orelse return null,
            .string_from_variant = get_to(.string) orelse return null,
            .string_to_variant = get_from(.string) orelse return null,
            .string_name_from_variant = get_to(.string_name) orelse return null,
            .string_name_to_variant = get_from(.string_name) orelse return null,
            .vector2_from_variant = get_to(.vector2) orelse return null,
            .vector2_to_variant = get_from(.vector2) orelse return null,
            .vector3_from_variant = get_to(.vector3) orelse return null,
            .vector3_to_variant = get_from(.vector3) orelse return null,
            .classdb_construct_object2 = resolveOne(ClassdbConstructObject2, get, "classdb_construct_object2") orelse return null,
            .object_set_instance = resolveOne(ObjectSetInstance, get, "object_set_instance") orelse return null,
            .object_set_instance_binding = resolveOne(ObjectSetInstanceBinding, get, "object_set_instance_binding") orelse return null,
            .object_destroy = resolveOne(ObjectDestroy, get, "object_destroy") orelse return null,
            .object_cast_to = resolveOne(ObjectCastTo, get, "object_cast_to") orelse return null,
            .classdb_get_class_tag = resolveOne(ClassdbGetClassTag, get, "classdb_get_class_tag") orelse return null,
            .object_from_variant = get_to(.object) orelse return null,
            .object_to_variant = get_from(.object) orelse return null,
            .classdb_register_extension_class5 = resolveOne(ClassdbRegisterExtensionClass5, get, "classdb_register_extension_class5") orelse return null,
            .classdb_register_extension_class_method = resolveOne(ClassdbRegisterExtensionClassMethod, get, "classdb_register_extension_class_method") orelse return null,
            .classdb_unregister_extension_class = resolveOne(ClassdbUnregisterExtensionClass, get, "classdb_unregister_extension_class") orelse return null,
        };
    }
};

fn resolveOne(comptime T: type, get: *const fn ([*:0]const u8) callconv(.c) InterfaceFunctionPtr, comptime name: [:0]const u8) ?T {
    const raw = get(name.ptr) orelse return null;
    return @ptrCast(raw);
}
