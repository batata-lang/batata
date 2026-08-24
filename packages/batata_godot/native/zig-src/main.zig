//! Fixed raw GDExtension adapter for Batata's first Godot target.

const std = @import("std");
const build_options = @import("build_options");
const term_runtime = @import("term_runtime");
const godot = @import("godot.zig");

const class_name_z = build_options.class_name ++ "\x00";
const base_class_name_z = build_options.base_class_name ++ "\x00";
const max_method_arity = 8;
const method_name_storage_width = 128;
const nil_word: i64 = 1;

const ValueType = enum {
    nil_value,
    bool_value,
    int_value,
    float_value,
};

const MethodSpec = struct {
    name: []const u8,
    symbol: []const u8,
    arguments: [max_method_arity]ValueType,
    arity: usize,
    returns: ValueType,
};

const method_specs = parseMethods(build_options.method_specs);
const Invoke = *const fn (*const [max_method_arity]i64) callconv(.c) i64;

const MethodRuntime = struct {
    spec: MethodSpec,
    invoke: Invoke,
};

const Instance = struct {
    magic: u64,
};

const InvocationContext = struct {
    method: *const MethodRuntime,
    arguments: *const [max_method_arity]i64,
};

const instance_magic: u64 = 0x4241_5441_5441_4744;

var api: godot.Api = undefined;
var library: godot.ClassLibraryPtr = null;
var class_name_storage: [8]u8 align(8) = undefined;
var base_class_name_storage: [8]u8 align(8) = undefined;
var empty_string_name_storage: [8]u8 align(8) = undefined;
var empty_string_storage: [8]u8 align(8) = undefined;
var method_name_storage: [method_specs.len][8]u8 align(8) = undefined;
var method_name_chars: [method_specs.len][method_name_storage_width]u8 = undefined;
var method_runtimes = makeMethodRuntimes();
var live_instances = std.atomic.Value(usize).init(0);
var class_registered = false;

const binding_callbacks = godot.InstanceBindingCallbacks{
    .create_callback = null,
    .free_callback = null,
    .reference_callback = null,
};

fn parseMethods(comptime encoded: []const u8) [methodCount(encoded)]MethodSpec {
    comptime {
        var result: [methodCount(encoded)]MethodSpec = undefined;
        var methods = std.mem.splitScalar(u8, encoded, ';');
        var method_index: usize = 0;

        while (methods.next()) |method| : (method_index += 1) {
            var fields = std.mem.splitScalar(u8, method, '|');
            const name = fields.next() orelse @compileError("Batata.Godot method spec is missing its name");
            const function_symbol = fields.next() orelse @compileError("Batata.Godot method spec is missing its symbol");
            const arguments = fields.next() orelse @compileError("Batata.Godot method spec is missing its arguments");
            const return_type = fields.next() orelse @compileError("Batata.Godot method spec is missing its return type");
            if (fields.next() != null) @compileError("Batata.Godot method spec contains extra fields");
            if (name.len == 0 or function_symbol.len == 0) @compileError("Batata.Godot method names and symbols must not be empty");
            if (name.len >= method_name_storage_width) @compileError("Batata.Godot method names must contain fewer than 128 bytes");

            var argument_types = [_]ValueType{.nil_value} ** max_method_arity;
            var arity: usize = 0;
            if (arguments.len != 0) {
                var argument_iterator = std.mem.splitScalar(u8, arguments, ',');
                while (argument_iterator.next()) |argument| : (arity += 1) {
                    if (arity == max_method_arity) @compileError("Batata.Godot methods support at most 8 arguments");
                    argument_types[arity] = parseValueType(argument);
                }
            }

            result[method_index] = .{
                .name = name,
                .symbol = function_symbol,
                .arguments = argument_types,
                .arity = arity,
                .returns = parseValueType(return_type),
            };
        }
        return result;
    }
}

fn methodCount(comptime encoded: []const u8) usize {
    if (encoded.len == 0) return 0;
    return std.mem.count(u8, encoded, ";") + 1;
}

fn parseValueType(comptime encoded: []const u8) ValueType {
    if (std.mem.eql(u8, encoded, "nil")) return .nil_value;
    if (std.mem.eql(u8, encoded, "bool")) return .bool_value;
    if (std.mem.eql(u8, encoded, "int")) return .int_value;
    if (std.mem.eql(u8, encoded, "float")) return .float_value;
    @compileError("Batata.Godot method spec contains an unsupported Variant type: " ++ encoded);
}

fn Invocation(comptime spec: MethodSpec) type {
    return struct {
        fn call(arguments: *const [max_method_arity]i64) callconv(.c) i64 {
            return switch (spec.arity) {
                0 => @extern(*const fn () callconv(.c) i64, .{ .name = spec.symbol })(),
                1 => @extern(*const fn (i64) callconv(.c) i64, .{ .name = spec.symbol })(arguments[0]),
                2 => @extern(*const fn (i64, i64) callconv(.c) i64, .{ .name = spec.symbol })(arguments[0], arguments[1]),
                3 => @extern(*const fn (i64, i64, i64) callconv(.c) i64, .{ .name = spec.symbol })(arguments[0], arguments[1], arguments[2]),
                4 => @extern(*const fn (i64, i64, i64, i64) callconv(.c) i64, .{ .name = spec.symbol })(arguments[0], arguments[1], arguments[2], arguments[3]),
                5 => @extern(*const fn (i64, i64, i64, i64, i64) callconv(.c) i64, .{ .name = spec.symbol })(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4]),
                6 => @extern(*const fn (i64, i64, i64, i64, i64, i64) callconv(.c) i64, .{ .name = spec.symbol })(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5]),
                7 => @extern(*const fn (i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64, .{ .name = spec.symbol })(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6]),
                8 => @extern(*const fn (i64, i64, i64, i64, i64, i64, i64, i64) callconv(.c) i64, .{ .name = spec.symbol })(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5], arguments[6], arguments[7]),
                else => unreachable,
            };
        }
    };
}

fn makeMethodRuntimes() [method_specs.len]MethodRuntime {
    comptime {
        var result: [method_specs.len]MethodRuntime = undefined;
        for (method_specs, 0..) |spec, index| {
            result[index] = .{ .spec = spec, .invoke = &Invocation(spec).call };
        }
        return result;
    }
}

fn variantType(value_type: ValueType) godot.VariantType {
    return switch (value_type) {
        .nil_value => .nil,
        .bool_value => .bool,
        .int_value => .int,
        .float_value => .float,
    };
}

fn metadata(value_type: ValueType) c_int {
    return switch (value_type) {
        .int_value => 4,
        .float_value => 10,
        else => 0,
    };
}

fn propertyInfo(value_type: ValueType) godot.PropertyInfo {
    return .{
        .variant_type = variantType(value_type),
        .name = &empty_string_name_storage,
        .class_name = &empty_string_name_storage,
        .hint = 0,
        .hint_string = &empty_string_storage,
        .usage = 6,
    };
}

fn createInstance(class_userdata: ?*anyopaque, notify_postinitialize: godot.Bool) callconv(.c) godot.ObjectPtr {
    _ = class_userdata;
    _ = notify_postinitialize;

    const memory = api.mem_alloc2(@sizeOf(Instance), 0) orelse return null;
    const instance: *Instance = @ptrCast(@alignCast(memory));
    instance.* = .{ .magic = instance_magic };

    const object = api.classdb_construct_object2(&base_class_name_storage) orelse {
        instance.magic = 0;
        api.mem_free2(memory, 0);
        return null;
    };

    api.object_set_instance(object, &class_name_storage, instance);
    api.object_set_instance_binding(object, library, instance, &binding_callbacks);
    _ = live_instances.fetchAdd(1, .acq_rel);
    return object;
}

fn freeInstance(class_userdata: ?*anyopaque, class_instance: godot.ClassInstancePtr) callconv(.c) void {
    _ = class_userdata;
    const instance_ptr = class_instance orelse return;
    const instance: *Instance = @ptrCast(@alignCast(instance_ptr));
    if (instance.magic != instance_magic) return;
    instance.magic = 0;
    _ = live_instances.fetchSub(1, .acq_rel);
    api.mem_free2(instance, 0);
}

fn invokeProtected(encoded_context: i64) callconv(.c) i64 {
    const address: u64 = @bitCast(encoded_context);
    const context: *const InvocationContext = @ptrFromInt(@as(usize, @intCast(address)));
    return context.method.invoke(context.arguments);
}

fn methodCall(
    method_userdata: ?*anyopaque,
    class_instance: godot.ClassInstancePtr,
    argument_variants: ?[*]const godot.ConstVariantPtr,
    argument_count: godot.Int,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) callconv(.c) void {
    call_error.* = .{ .error_code = .ok, .argument = 0, .expected = 0 };

    const instance_opaque = class_instance orelse {
        return failCall(call_error, .instance_is_null, -1, 0, "E_GODOT_OBJECT_HANDLE_STALE");
    };
    const instance: *const Instance = @ptrCast(@alignCast(instance_opaque));
    if (instance.magic != instance_magic) {
        return failCall(call_error, .instance_is_null, -1, 0, "E_GODOT_OBJECT_HANDLE_STALE");
    }

    const method_opaque = method_userdata orelse {
        return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_METHOD_MISSING");
    };
    const method: *const MethodRuntime = @ptrCast(@alignCast(method_opaque));

    if (argument_count < @as(godot.Int, @intCast(method.spec.arity))) {
        return failCall(call_error, .too_few_arguments, @intCast(argument_count), @intCast(method.spec.arity), "E_GODOT_METHOD_ARGUMENT_COUNT");
    }
    if (argument_count > @as(godot.Int, @intCast(method.spec.arity))) {
        return failCall(call_error, .too_many_arguments, @intCast(method.spec.arity), @intCast(method.spec.arity), "E_GODOT_METHOD_ARGUMENT_COUNT");
    }
    if (method.spec.arity != 0 and argument_variants == null) {
        return failCall(call_error, .invalid_argument, 0, 0, "E_GODOT_METHOD_ARGUMENT_MISSING");
    }

    const runtime_handle = term_runtime.ex_term_runtime_create();
    if (runtime_handle <= 0 or term_runtime.ex_term_runtime_enter(runtime_handle) != 0) {
        if (runtime_handle > 0) _ = term_runtime.ex_term_runtime_destroy(runtime_handle);
        return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_RUNTIME_BUSY");
    }

    var arguments = [_]i64{nil_word} ** max_method_arity;
    for (0..method.spec.arity) |index| {
        const source = argument_variants.?[index];
        const expected = method.spec.arguments[index];
        const actual = api.variant_get_type(source);
        if (actual != variantType(expected)) {
            abandonRuntime(runtime_handle);
            return failCall(call_error, .invalid_argument, @intCast(index), @intFromEnum(variantType(expected)), "E_GODOT_METHOD_SIGNATURE_UNSUPPORTED");
        }

        arguments[index] = switch (expected) {
            .nil_value => nil_word,
            .bool_value => blk: {
                var value: godot.Bool = 0;
                api.bool_from_variant(&value, @constCast(source));
                break :blk if (value == 0) build_options.false_word else build_options.true_word;
            },
            .int_value => blk: {
                var value: i64 = 0;
                api.int_from_variant(&value, @constCast(source));
                if (value < -(@as(i64, 1) << 60) or value > (@as(i64, 1) << 60) - 1) {
                    abandonRuntime(runtime_handle);
                    return failCall(call_error, .invalid_argument, @intCast(index), @intFromEnum(godot.VariantType.int), "E_GODOT_INTEGER_OUT_OF_RANGE");
                }
                break :blk value;
            },
            .float_value => blk: {
                var value: f64 = 0;
                api.float_from_variant(&value, @constCast(source));
                break :blk term_runtime.ex_term_float_lit(@bitCast(value));
            },
        };
    }

    const invocation = InvocationContext{ .method = method, .arguments = &arguments };
    var caught: i64 = 0;
    var exception_kind: i64 = 0;
    const encoded_context: i64 = @bitCast(@as(u64, @intFromPtr(&invocation)));
    const result_word = term_runtime.ex_term_protected_call(
        &invokeProtected,
        encoded_context,
        &caught,
        &exception_kind,
    );

    if (caught != 0) {
        abandonRuntime(runtime_handle);
        return failCall(call_error, .invalid_method, -1, @intCast(exception_kind), "E_GODOT_COMPILED_EXCEPTION");
    }

    if (method.spec.returns != .float_value) {
        abandonRuntime(runtime_handle);
        return writeImmediateResult(method.spec.returns, result_word, return_variant, call_error);
    }

    if (term_runtime.ex_term_is_float(result_word) == 0) {
        abandonRuntime(runtime_handle);
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.float), "E_GODOT_RETURN_TYPE_MISMATCH");
    }
    const bits = term_runtime.ex_term_float_bits(result_word);
    var value: f64 = @bitCast(bits);
    abandonRuntime(runtime_handle);
    api.float_to_variant(return_variant, &value);
}

fn writeImmediateResult(
    return_type: ValueType,
    result_word: i64,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) void {
    switch (return_type) {
        .nil_value => {
            if (result_word != nil_word) return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_RETURN_TYPE_MISMATCH");
            api.variant_new_nil(return_variant);
        },
        .bool_value => {
            var value: godot.Bool = if (result_word == build_options.true_word)
                1
            else if (result_word == build_options.false_word)
                0
            else
                return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.bool), "E_GODOT_RETURN_TYPE_MISMATCH");
            api.bool_to_variant(return_variant, &value);
        },
        .int_value => {
            var value = result_word;
            api.int_to_variant(return_variant, &value);
        },
        .float_value => unreachable,
    }
}

fn abandonRuntime(runtime_handle: i64) void {
    _ = term_runtime.ex_term_runtime_leave();
    _ = term_runtime.ex_term_runtime_destroy(runtime_handle);
}

fn failCall(call_error: *godot.CallError, error_code: godot.CallErrorType, argument: i32, expected: i32, comptime message: [:0]const u8) void {
    call_error.* = .{ .error_code = error_code, .argument = argument, .expected = expected };
    api.print_error(message.ptr, "Batata.Godot.methodCall", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
}

fn initialize(userdata: ?*anyopaque, level: godot.InitializationLevel) callconv(.c) void {
    _ = userdata;
    if (level != build_options.initialization_level or class_registered) return;

    api.string_name_new_with_latin1_chars(&class_name_storage, @ptrCast(class_name_z.ptr), 1);
    api.string_name_new_with_latin1_chars(&base_class_name_storage, @ptrCast(base_class_name_z.ptr), 1);
    api.string_name_new_with_latin1_chars(&empty_string_name_storage, "", 1);
    api.string_new_with_utf8_chars(&empty_string_storage, "");

    const creation_info = godot.ClassCreationInfo5{
        .is_virtual = 0,
        .is_abstract = 0,
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
        .create_instance_func = &createInstance,
        .free_instance_func = &freeInstance,
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

    for (&method_runtimes, 0..) |*method, index| {
        @memcpy(method_name_chars[index][0..method.spec.name.len], method.spec.name);
        method_name_chars[index][method.spec.name.len] = 0;
        api.string_name_new_with_latin1_chars(&method_name_storage[index], @ptrCast(method_name_chars[index][0..].ptr), 1);

        var argument_info: [max_method_arity]godot.PropertyInfo = undefined;
        var argument_metadata: [max_method_arity]c_int = undefined;
        for (0..method.spec.arity) |argument_index| {
            argument_info[argument_index] = propertyInfo(method.spec.arguments[argument_index]);
            argument_metadata[argument_index] = metadata(method.spec.arguments[argument_index]);
        }

        var return_info = propertyInfo(method.spec.returns);
        const method_info = godot.ClassMethodInfo{
            .name = &method_name_storage[index],
            .method_userdata = method,
            .call_func = &methodCall,
            .ptrcall_func = null,
            .method_flags = 1,
            .has_return_value = if (method.spec.returns == .nil_value) 0 else 1,
            .return_value_info = if (method.spec.returns == .nil_value) null else &return_info,
            .return_value_metadata = metadata(method.spec.returns),
            .argument_count = @intCast(method.spec.arity),
            .arguments_info = if (method.spec.arity == 0) null else argument_info[0..method.spec.arity].ptr,
            .arguments_metadata = if (method.spec.arity == 0) null else argument_metadata[0..method.spec.arity].ptr,
            .default_argument_count = 0,
            .default_arguments = null,
        };
        api.classdb_register_extension_class_method(library, &class_name_storage, &method_info);
    }
    class_registered = true;
}

fn deinitialize(userdata: ?*anyopaque, level: godot.InitializationLevel) callconv(.c) void {
    _ = userdata;
    if (level != build_options.initialization_level or !class_registered) return;
    if (live_instances.load(.acquire) != 0) {
        api.print_error("E_GODOT_RUNTIME_BUSY", "Batata.Godot.deinitialize", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
    }
    api.classdb_unregister_extension_class(library, &class_name_storage);
    api.string_destructor(&empty_string_storage);
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

    if (method_specs.len == 0) {
        @compileError("Batata.Godot extensions must declare at least one method");
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
