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
const max_packed_elements: i64 = 4_000_000;
const mesh_array_slots: i64 = 13;
const mesh_array_vertex_slot: i64 = 0;
const mesh_array_index_slot: i64 = 12;

const ValueType = enum {
    nil_value,
    bool_value,
    int_value,
    float_value,
    string_value,
    string_name_value,
    vector2_value,
    vector3_value,
    packed_vector3_array_value,
    packed_int32_array_value,
    array_mesh_surface_value,
    object_value,
};

const Outbound = enum { none, array_mesh_surface };
const StatePolicy = enum { none, replace };

const MethodSpec = struct {
    name: []const u8,
    symbol: []const u8,
    arguments: [max_method_arity]ValueType,
    argument_object_classes: [max_method_arity][]const u8,
    arity: usize,
    returns: ValueType,
    return_object_class: []const u8,
    outbound: Outbound,
    state: StatePolicy,
};

const PropertySpec = struct {
    name: []const u8,
    value_type: ValueType,
    getter: []const u8,
    setter: []const u8,
};

const SignalSpec = struct {
    name: []const u8,
    arguments: [max_method_arity]ValueType,
    arity: usize,
};

const method_specs = parseMethods(build_options.method_specs);
const property_specs = parseProperties(build_options.property_specs);
const signal_specs = parseSignals(build_options.signal_specs);
const virtual_specs = parseVirtuals(build_options.virtual_specs);
const has_array_mesh_outbound = blk: {
    for (method_specs) |spec| {
        if (spec.outbound == .array_mesh_surface) break :blk true;
    }
    break :blk false;
};
const Invoke = *const fn (*const [max_method_arity]i64) callconv(.c) i64;

const MethodRuntime = struct {
    spec: MethodSpec,
    invoke: Invoke,
};

const Instance = struct {
    magic: u64,
    runtime_handle: i64,
    portable_state: i64,
    generation: u64,
};

const InvocationContext = struct {
    method: *const MethodRuntime,
    arguments: *const [max_method_arity]i64,
};

const ObjectCapability = extern struct {
    generation: u64,
    slot: u32,
    guard: u32,
};

const ObjectLease = struct {
    object: godot.ObjectPtr,
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
var property_name_storage: [property_specs.len][8]u8 align(8) = undefined;
var property_name_chars: [property_specs.len][method_name_storage_width]u8 = undefined;
var property_getter_storage: [property_specs.len][8]u8 align(8) = undefined;
var property_getter_chars: [property_specs.len][method_name_storage_width]u8 = undefined;
var property_setter_storage: [property_specs.len][8]u8 align(8) = undefined;
var property_setter_chars: [property_specs.len][method_name_storage_width]u8 = undefined;
var signal_name_storage: [signal_specs.len][8]u8 align(8) = undefined;
var signal_name_chars: [signal_specs.len][method_name_storage_width]u8 = undefined;
var virtual_runtimes = makeVirtualRuntimes();
var method_runtimes = makeMethodRuntimes();
var live_instances = std.atomic.Value(usize).init(0);
var invocation_generation = std.atomic.Value(u64).init(1);
var initialization_thread: std.Thread.Id = undefined;
var class_registered = false;
var array_mesh_add_surface_method: godot.MethodBindPtr = null;

const binding_callbacks = godot.InstanceBindingCallbacks{
    .create_callback = null,
    .free_callback = null,
    .reference_callback = null,
};

fn parseMethods(comptime encoded: []const u8) [methodCount(encoded)]MethodSpec {
    comptime {
        @setEvalBranchQuota(10_000);
        var result: [methodCount(encoded)]MethodSpec = undefined;
        var methods = std.mem.splitScalar(u8, encoded, ';');
        var method_index: usize = 0;

        while (methods.next()) |method| : (method_index += 1) {
            var fields = std.mem.splitScalar(u8, method, '|');
            const name = fields.next() orelse @compileError("Batata.Godot method spec is missing its name");
            const function_symbol = fields.next() orelse @compileError("Batata.Godot method spec is missing its symbol");
            const arguments = fields.next() orelse @compileError("Batata.Godot method spec is missing its arguments");
            const return_type = fields.next() orelse @compileError("Batata.Godot method spec is missing its return type");
            const outbound = fields.next() orelse @compileError("Batata.Godot method spec is missing its outbound operation");
            const state = fields.next() orelse @compileError("Batata.Godot method spec is missing its state policy");
            if (fields.next() != null) @compileError("Batata.Godot method spec contains extra fields");
            if (name.len == 0 or function_symbol.len == 0) @compileError("Batata.Godot method names and symbols must not be empty");
            if (name.len >= method_name_storage_width) @compileError("Batata.Godot method names must contain fewer than 128 bytes");

            var argument_types = [_]ValueType{.nil_value} ** max_method_arity;
            var argument_object_classes = [_][]const u8{""} ** max_method_arity;
            var arity: usize = 0;
            if (arguments.len != 0) {
                var argument_iterator = std.mem.splitScalar(u8, arguments, ',');
                while (argument_iterator.next()) |argument| : (arity += 1) {
                    if (arity == max_method_arity) @compileError("Batata.Godot methods support at most 8 arguments");
                    argument_types[arity] = parseValueType(argument);
                    argument_object_classes[arity] = parseObjectClass(argument);
                }
            }

            result[method_index] = .{
                .name = name,
                .symbol = function_symbol,
                .arguments = argument_types,
                .argument_object_classes = argument_object_classes,
                .arity = arity,
                .returns = parseValueType(return_type),
                .return_object_class = parseObjectClass(return_type),
                .outbound = parseOutbound(outbound),
                .state = parseStatePolicy(state),
            };
        }
        return result;
    }
}

fn methodCount(comptime encoded: []const u8) usize {
    if (encoded.len == 0) return 0;
    return std.mem.count(u8, encoded, ";") + 1;
}

fn parseProperties(comptime encoded: []const u8) [methodCount(encoded)]PropertySpec {
    comptime {
        @setEvalBranchQuota(10_000);
        var result: [methodCount(encoded)]PropertySpec = undefined;
        if (encoded.len == 0) return result;
        var descriptors = std.mem.splitScalar(u8, encoded, ';');
        var index: usize = 0;
        while (descriptors.next()) |descriptor| : (index += 1) {
            var fields = std.mem.splitScalar(u8, descriptor, '|');
            const name = fields.next() orelse @compileError("Godot property is missing its name");
            const value_type = fields.next() orelse @compileError("Godot property is missing its type");
            const getter = fields.next() orelse @compileError("Godot property is missing its getter");
            const setter = fields.next() orelse @compileError("Godot property is missing its setter");
            if (fields.next() != null) @compileError("Godot property contains extra fields");
            validateDescriptorName(name);
            validateDescriptorName(getter);
            validateDescriptorName(setter);
            result[index] = .{
                .name = name,
                .value_type = parseValueType(value_type),
                .getter = getter,
                .setter = setter,
            };
        }
        return result;
    }
}

fn parseSignals(comptime encoded: []const u8) [methodCount(encoded)]SignalSpec {
    comptime {
        @setEvalBranchQuota(10_000);
        var result: [methodCount(encoded)]SignalSpec = undefined;
        if (encoded.len == 0) return result;
        var descriptors = std.mem.splitScalar(u8, encoded, ';');
        var index: usize = 0;
        while (descriptors.next()) |descriptor| : (index += 1) {
            var fields = std.mem.splitScalar(u8, descriptor, '|');
            const name = fields.next() orelse @compileError("Godot signal is missing its name");
            const arguments = fields.next() orelse @compileError("Godot signal is missing its arguments");
            if (fields.next() != null) @compileError("Godot signal contains extra fields");
            validateDescriptorName(name);
            var argument_types = [_]ValueType{.nil_value} ** max_method_arity;
            var arity: usize = 0;
            if (arguments.len != 0) {
                var iterator = std.mem.splitScalar(u8, arguments, ',');
                while (iterator.next()) |argument| : (arity += 1) {
                    if (arity == max_method_arity) @compileError("Godot signals support at most 8 arguments");
                    argument_types[arity] = parseValueType(argument);
                }
            }
            result[index] = .{ .name = name, .arguments = argument_types, .arity = arity };
        }
        return result;
    }
}

fn parseVirtuals(comptime encoded: []const u8) [methodCount(encoded)]MethodSpec {
    comptime {
        @setEvalBranchQuota(10_000);
        var result: [methodCount(encoded)]MethodSpec = undefined;
        if (encoded.len == 0) return result;
        var descriptors = std.mem.splitScalar(u8, encoded, ';');
        var index: usize = 0;
        while (descriptors.next()) |descriptor| : (index += 1) {
            var fields = std.mem.splitScalar(u8, descriptor, '|');
            const name = fields.next() orelse @compileError("Godot virtual is missing its name");
            const function_symbol = fields.next() orelse @compileError("Godot virtual is missing its symbol");
            const arguments = fields.next() orelse @compileError("Godot virtual is missing its arguments");
            if (fields.next() != null) @compileError("Godot virtual contains extra fields");
            validateDescriptorName(name);
            var argument_types = [_]ValueType{.nil_value} ** max_method_arity;
            var arity: usize = 0;
            if (arguments.len != 0) {
                var iterator = std.mem.splitScalar(u8, arguments, ',');
                while (iterator.next()) |argument| : (arity += 1) {
                    if (arity == max_method_arity) @compileError("Godot virtuals support at most 8 arguments");
                    argument_types[arity] = parseValueType(argument);
                }
            }
            result[index] = .{
                .name = name,
                .symbol = function_symbol,
                .arguments = argument_types,
                .argument_object_classes = [_][]const u8{""} ** max_method_arity,
                .arity = arity,
                .returns = .nil_value,
                .return_object_class = "",
                .outbound = .none,
                .state = .none,
            };
        }
        return result;
    }
}

fn validateDescriptorName(comptime name: []const u8) void {
    if (name.len == 0 or name.len >= method_name_storage_width) {
        @compileError("Godot descriptor names must contain 1 to 127 bytes");
    }
}

fn parseValueType(comptime encoded: []const u8) ValueType {
    if (std.mem.eql(u8, encoded, "nil")) return .nil_value;
    if (std.mem.eql(u8, encoded, "bool")) return .bool_value;
    if (std.mem.eql(u8, encoded, "int")) return .int_value;
    if (std.mem.eql(u8, encoded, "float")) return .float_value;
    if (std.mem.eql(u8, encoded, "string")) return .string_value;
    if (std.mem.eql(u8, encoded, "string_name")) return .string_name_value;
    if (std.mem.eql(u8, encoded, "vector2")) return .vector2_value;
    if (std.mem.eql(u8, encoded, "vector3")) return .vector3_value;
    if (std.mem.eql(u8, encoded, "packed_vector3_array")) return .packed_vector3_array_value;
    if (std.mem.eql(u8, encoded, "packed_int32_array")) return .packed_int32_array_value;
    if (std.mem.eql(u8, encoded, "array_mesh_surface")) return .array_mesh_surface_value;
    if (std.mem.startsWith(u8, encoded, "object:") and encoded.len > "object:".len) return .object_value;
    @compileError("Batata.Godot method spec contains an unsupported Variant type: " ++ encoded);
}

fn parseOutbound(comptime encoded: []const u8) Outbound {
    if (encoded.len == 0) return .none;
    if (std.mem.eql(u8, encoded, "array_mesh_surface")) return .array_mesh_surface;
    @compileError("Batata.Godot method spec contains an undeclared outbound operation: " ++ encoded);
}

fn parseStatePolicy(comptime encoded: []const u8) StatePolicy {
    if (encoded.len == 0) return .none;
    if (std.mem.eql(u8, encoded, "replace")) return .replace;
    @compileError("Batata.Godot method state policy is not supported");
}

fn parseObjectClass(comptime encoded: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, encoded, "object:")) return "";
    const class_name = encoded["object:".len..];
    if (class_name.len == 0 or class_name.len >= method_name_storage_width) {
        @compileError("Batata.Godot object class names must contain 1 to 127 bytes");
    }
    return class_name;
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

fn makeVirtualRuntimes() [virtual_specs.len]MethodRuntime {
    comptime {
        var result: [virtual_specs.len]MethodRuntime = undefined;
        for (virtual_specs, 0..) |spec, index| {
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
        .string_value => .string,
        .string_name_value => .string_name,
        .vector2_value => .vector2,
        .vector3_value => .vector3,
        .packed_vector3_array_value => .packed_vector3_array,
        .packed_int32_array_value => .packed_int32_array,
        .array_mesh_surface_value => .array,
        .object_value => .object,
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
    const runtime_handle = term_runtime.ex_term_runtime_create();
    if (runtime_handle <= 0) {
        api.mem_free2(memory, 0);
        api.print_error("E_GODOT_INSTANCE_STATE_UNAVAILABLE", "Batata.Godot.createInstance", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
        return null;
    }
    instance.* = .{
        .magic = instance_magic,
        .runtime_handle = runtime_handle,
        .portable_state = 0,
        .generation = invocation_generation.fetchAdd(1, .acq_rel),
    };

    const object = api.classdb_construct_object2(&base_class_name_storage) orelse {
        instance.magic = 0;
        _ = term_runtime.ex_term_runtime_destroy(runtime_handle);
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
    if (instance.portable_state > 0) {
        _ = term_runtime.ex_term_exported_destroy(instance.portable_state);
        instance.portable_state = 0;
    }
    if (term_runtime.ex_term_runtime_destroy(instance.runtime_handle) != 0) {
        api.print_error("E_GODOT_INSTANCE_STATE_STALE", "Batata.Godot.freeInstance", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
    }
    instance.runtime_handle = 0;
    instance.generation +%= 1;
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
    if (std.Thread.getCurrentId() != initialization_thread) {
        return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_WRONG_THREAD");
    }

    const instance_opaque = class_instance orelse {
        return failCall(call_error, .instance_is_null, -1, 0, "E_GODOT_OBJECT_HANDLE_STALE");
    };
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));
    if (instance.magic != instance_magic or instance.runtime_handle <= 0) {
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

    const runtime_handle = instance.runtime_handle;
    if (term_runtime.ex_term_runtime_enter(runtime_handle) != 0) {
        return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_RUNTIME_BUSY");
    }
    if (term_runtime.ex_term_process_table_reset(256) != 1) {
        leaveRuntime();
        return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_INSTANCE_STATE_UNAVAILABLE");
    }

    var arguments = [_]i64{nil_word} ** max_method_arity;
    var object_leases = [_]ObjectLease{.{ .object = null }} ** max_method_arity;
    var object_lease_count: usize = 0;
    const generation = invocation_generation.fetchAdd(1, .acq_rel);
    for (0..method.spec.arity) |index| {
        const source = argument_variants.?[index];
        const expected = method.spec.arguments[index];
        const actual = api.variant_get_type(source);
        if (actual != variantType(expected)) {
            leaveRuntime();
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
                    leaveRuntime();
                    return failCall(call_error, .invalid_argument, @intCast(index), @intFromEnum(godot.VariantType.int), "E_GODOT_INTEGER_OUT_OF_RANGE");
                }
                break :blk value;
            },
            .float_value => blk: {
                var value: f64 = 0;
                api.float_from_variant(&value, @constCast(source));
                break :blk term_runtime.ex_term_float_lit(@bitCast(value));
            },
            .string_value, .string_name_value => textVariantToTerm(expected, @constCast(source)) orelse {
                leaveRuntime();
                return failCall(call_error, .invalid_argument, @intCast(index), @intFromEnum(variantType(expected)), "E_GODOT_STRING_CONVERSION_FAILED");
            },
            .vector2_value => blk: {
                var value: godot.Vector2 = undefined;
                api.vector2_from_variant(&value, @constCast(source));
                break :blk vectorToTerm(&.{ value.x, value.y });
            },
            .vector3_value => blk: {
                var value: godot.Vector3 = undefined;
                api.vector3_from_variant(&value, @constCast(source));
                break :blk vectorToTerm(&.{ value.x, value.y, value.z });
            },
            .packed_vector3_array_value => packedVector3ArrayToTerm(@constCast(source)) orelse {
                leaveRuntime();
                return failCall(call_error, .invalid_argument, @intCast(index), @intFromEnum(godot.VariantType.packed_vector3_array), "E_GODOT_PACKED_ARRAY_CODEC_MISSING");
            },
            .packed_int32_array_value => packedInt32ArrayToTerm(@constCast(source)) orelse {
                leaveRuntime();
                return failCall(call_error, .invalid_argument, @intCast(index), @intFromEnum(godot.VariantType.packed_int32_array), "E_GODOT_PACKED_ARRAY_CODEC_MISSING");
            },
            .array_mesh_surface_value => {
                leaveRuntime();
                return failCall(call_error, .invalid_argument, @intCast(index), @intFromEnum(godot.VariantType.array), "E_GODOT_PACKED_ARRAY_CODEC_MISSING");
            },
            .object_value => objectVariantToTerm(
                @constCast(source),
                method.spec.argument_object_classes[index],
                &object_leases,
                &object_lease_count,
                generation,
            ) orelse {
                leaveRuntime();
                return failCall(call_error, .invalid_argument, @intCast(index), @intFromEnum(godot.VariantType.object), "E_GODOT_OBJECT_HANDLE_STALE");
            },
        };
    }

    const invocation = InvocationContext{ .method = method, .arguments = &arguments };
    var caught: i64 = 0;
    var exception_kind: i64 = 0;
    const encoded_context: i64 = @bitCast(@as(u64, @intFromPtr(&invocation)));
    const invocation_result = term_runtime.ex_term_protected_call(
        &invokeProtected,
        encoded_context,
        &caught,
        &exception_kind,
    );

    if (caught != 0) {
        leaveRuntime();
        return failCall(call_error, .invalid_method, -1, @intCast(exception_kind), "E_GODOT_COMPILED_EXCEPTION");
    }

    var result_word = invocation_result;
    var state_word = invocation_result;
    if (method.spec.state == .replace) {
        if (term_runtime.ex_term_is_tuple(invocation_result) == 0 or
            term_runtime.ex_term_tuple_length(invocation_result) != 2)
        {
            leaveRuntime();
            return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_EDITOR_STATE_SHAPE_INVALID");
        }
        state_word = term_runtime.ex_term_tuple_get(invocation_result, 0);
        result_word = term_runtime.ex_term_tuple_get(invocation_result, 1);
    }

    if (method.spec.returns != .float_value and method.spec.returns != .string_value and method.spec.returns != .string_name_value and method.spec.returns != .vector2_value and method.spec.returns != .vector3_value and method.spec.returns != .packed_vector3_array_value and method.spec.returns != .packed_int32_array_value and method.spec.returns != .array_mesh_surface_value and method.spec.returns != .object_value) {
        writeImmediateResult(method.spec.returns, result_word, return_variant, call_error);
        return finishMethodCall(instance, method, state_word, call_error);
    }

    if (method.spec.returns == .string_value or method.spec.returns == .string_name_value) {
        writeTextResult(method.spec.returns, result_word, return_variant, call_error);
        return finishMethodCall(instance, method, state_word, call_error);
    }

    if (method.spec.returns == .vector2_value or method.spec.returns == .vector3_value) {
        writeVectorResult(method.spec.returns, result_word, return_variant, call_error);
        return finishMethodCall(instance, method, state_word, call_error);
    }

    if (method.spec.returns == .packed_vector3_array_value) {
        writePackedVector3ArrayResult(result_word, return_variant, call_error);
        return finishMethodCall(instance, method, state_word, call_error);
    }

    if (method.spec.returns == .packed_int32_array_value) {
        writePackedInt32ArrayResult(result_word, return_variant, call_error);
        return finishMethodCall(instance, method, state_word, call_error);
    }

    if (method.spec.returns == .array_mesh_surface_value) {
        writeArrayMeshSurfaceResult(result_word, return_variant, call_error);
        return finishMethodCall(instance, method, state_word, call_error);
    }

    if (method.spec.outbound == .array_mesh_surface) {
        writeArrayMeshObjectResult(result_word, return_variant, call_error);
        return finishMethodCall(instance, method, state_word, call_error);
    }

    if (method.spec.returns == .object_value) {
        writeObjectResult(
            result_word,
            method.spec.return_object_class,
            &object_leases,
            object_lease_count,
            generation,
            return_variant,
            call_error,
        );
        return finishMethodCall(instance, method, state_word, call_error);
    }

    if (term_runtime.ex_term_is_float(result_word) == 0) {
        leaveRuntime();
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.float), "E_GODOT_RETURN_TYPE_MISMATCH");
    }
    const bits = term_runtime.ex_term_float_bits(result_word);
    var value: f64 = @bitCast(bits);
    api.float_to_variant(return_variant, &value);
    finishMethodCall(instance, method, state_word, call_error);
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
        .string_value, .string_name_value => unreachable,
        .vector2_value, .vector3_value => unreachable,
        .packed_vector3_array_value, .packed_int32_array_value, .array_mesh_surface_value => unreachable,
        .object_value => unreachable,
    }
}

fn vectorToTerm(components: []const f32) i64 {
    var list = nil_word;
    var index = components.len;
    while (index != 0) {
        index -= 1;
        const component: f64 = components[index];
        list = term_runtime.ex_term_list_cons(term_runtime.ex_term_float_lit(@bitCast(component)), list);
    }
    return term_runtime.ex_term_tuple_from_list(list);
}

fn writeVectorResult(
    value_type: ValueType,
    result_word: i64,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) void {
    const expected_length: i64 = if (value_type == .vector2_value) 2 else 3;
    if (term_runtime.ex_term_is_tuple(result_word) == 0 or term_runtime.ex_term_tuple_length(result_word) != expected_length) {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(variantType(value_type)), "E_GODOT_RETURN_TYPE_MISMATCH");
    }

    var components = [_]f32{ 0, 0, 0 };
    for (0..@as(usize, @intCast(expected_length))) |index| {
        const component = term_runtime.ex_term_tuple_get(result_word, @intCast(index));
        if (term_runtime.ex_term_is_float(component) == 0) {
            return failCall(call_error, .invalid_method, @intCast(index), @intFromEnum(godot.VariantType.float), "E_GODOT_RETURN_TYPE_MISMATCH");
        }
        const value: f64 = @bitCast(term_runtime.ex_term_float_bits(component));
        components[index] = @floatCast(value);
    }

    if (value_type == .vector2_value) {
        var vector = godot.Vector2{ .x = components[0], .y = components[1] };
        api.vector2_to_variant(return_variant, &vector);
    } else {
        var vector = godot.Vector3{ .x = components[0], .y = components[1], .z = components[2] };
        api.vector3_to_variant(return_variant, &vector);
    }
}

fn packedVector3ArrayToTerm(source: godot.VariantPtr) ?i64 {
    var storage: [16]u8 align(8) = undefined;
    api.packed_vector3_array_from_variant(&storage, source);
    defer api.packed_vector3_array_destructor(&storage);
    const length = packedSize(api.packed_vector3_array_size, &storage) orelse return null;
    if (length > max_packed_elements) return null;

    var list = nil_word;
    var index = length;
    while (index != 0) {
        index -= 1;
        const raw = api.packed_vector3_array_operator_index_const(&storage, index) orelse return null;
        const vector: *const godot.Vector3 = @ptrCast(@alignCast(raw));
        list = term_runtime.ex_term_list_cons(vectorToTerm(&.{ vector.x, vector.y, vector.z }), list);
    }
    if (term_runtime.ex_term_list_length(list) != length) return null;
    return list;
}

fn packedInt32ArrayToTerm(source: godot.VariantPtr) ?i64 {
    var storage: [16]u8 align(8) = undefined;
    api.packed_int32_array_from_variant(&storage, source);
    defer api.packed_int32_array_destructor(&storage);
    const length = packedSize(api.packed_int32_array_size, &storage) orelse return null;
    if (length > max_packed_elements) return null;

    var list = nil_word;
    var index = length;
    while (index != 0) {
        index -= 1;
        const raw = api.packed_int32_array_operator_index_const(&storage, index) orelse return null;
        const value: *const i32 = @ptrCast(@alignCast(raw));
        list = term_runtime.ex_term_list_cons(@as(i64, value.*) * 8, list);
    }
    if (term_runtime.ex_term_list_length(list) != length) return null;
    return list;
}

fn packedSize(method: godot.PtrBuiltInMethod, value: godot.TypePtr) ?i64 {
    var length: i64 = -1;
    method(value, null, &length, 0);
    if (length < 0) return null;
    return length;
}

fn resizeBuiltin(method: godot.PtrBuiltInMethod, value: godot.TypePtr, length: i64) bool {
    var result: i64 = -1;
    const arguments = [_]godot.ConstTypePtr{&length};
    method(value, &arguments, &result, 1);
    return result == 0;
}

fn writePackedVector3ArrayResult(
    result_word: i64,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) void {
    var storage: [16]u8 align(8) = undefined;
    api.packed_vector3_array_constructor(&storage, null);
    defer api.packed_vector3_array_destructor(&storage);
    if (!fillPackedVector3Array(result_word, &storage, 1.0)) {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.packed_vector3_array), "E_GODOT_PACKED_ARRAY_CODEC_MISSING");
    }
    api.packed_vector3_array_to_variant(return_variant, &storage);
}

fn writePackedInt32ArrayResult(
    result_word: i64,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) void {
    var storage: [16]u8 align(8) = undefined;
    api.packed_int32_array_constructor(&storage, null);
    defer api.packed_int32_array_destructor(&storage);
    if (!fillPackedInt32Array(result_word, &storage)) {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.packed_int32_array), "E_GODOT_PACKED_ARRAY_CODEC_MISSING");
    }
    api.packed_int32_array_to_variant(return_variant, &storage);
}

fn fillPackedVector3Array(result_word: i64, storage: godot.TypePtr, scale: f32) bool {
    if (!std.math.isFinite(scale) or scale <= 0) return false;
    if (term_runtime.ex_term_is_list(result_word) == 0) return false;
    const length = term_runtime.ex_term_list_length(result_word);
    if (length < 0 or length > max_packed_elements or !resizeBuiltin(api.packed_vector3_array_resize, storage, length)) return false;

    var current = result_word;
    for (0..@as(usize, @intCast(length))) |index| {
        const tuple = term_runtime.ex_term_list_head(current);
        if (term_runtime.ex_term_is_tuple(tuple) == 0 or term_runtime.ex_term_tuple_length(tuple) != 3) return false;
        var vector: godot.Vector3 = undefined;
        inline for (0..3) |component| {
            const term = term_runtime.ex_term_tuple_get(tuple, component);
            const value = (termNumberToF32(term) orelse return false) / scale;
            switch (component) {
                0 => vector.x = value,
                1 => vector.y = value,
                2 => vector.z = value,
                else => unreachable,
            }
        }
        const destination = api.packed_vector3_array_operator_index(storage, @intCast(index)) orelse return false;
        const typed: *godot.Vector3 = @ptrCast(@alignCast(destination));
        typed.* = vector;
        current = term_runtime.ex_term_list_tail(current);
    }
    return current == nil_word;
}

fn termNumberToF32(term: i64) ?f32 {
    if (term_runtime.ex_term_is_float(term) != 0) {
        const value: f64 = @bitCast(term_runtime.ex_term_float_bits(term));
        return @floatCast(value);
    }
    if (term_runtime.ex_term_is_integer(term) != 0) {
        return @floatFromInt(term_runtime.ex_term_to_int(term));
    }
    return null;
}

fn fillPackedInt32Array(result_word: i64, storage: godot.TypePtr) bool {
    if (term_runtime.ex_term_is_list(result_word) == 0) return false;
    const length = term_runtime.ex_term_list_length(result_word);
    if (length < 0 or length > max_packed_elements or !resizeBuiltin(api.packed_int32_array_resize, storage, length)) return false;

    var current = result_word;
    for (0..@as(usize, @intCast(length))) |index| {
        const term = term_runtime.ex_term_list_head(current);
        if (term_runtime.ex_term_is_integer(term) == 0) return false;
        const value = term_runtime.ex_term_to_int(term);
        if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return false;
        const destination = api.packed_int32_array_operator_index(storage, @intCast(index)) orelse return false;
        const typed: *i32 = @ptrCast(@alignCast(destination));
        typed.* = @intCast(value);
        current = term_runtime.ex_term_list_tail(current);
    }
    return current == nil_word;
}

fn writeArrayMeshSurfaceResult(
    result_word: i64,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) void {
    var arrays: [8]u8 align(8) = undefined;
    api.array_constructor(&arrays, null);
    defer api.array_destructor(&arrays);
    if (!fillSurfaceArrays(result_word, &arrays)) {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.array), "E_GODOT_PACKED_ARRAY_CODEC_MISSING");
    }

    api.array_to_variant(return_variant, &arrays);
}

fn fillSurfaceArrays(result_word: i64, arrays: godot.TypePtr) bool {
    if (term_runtime.ex_term_is_tuple(result_word) == 0) return false;
    const descriptor_length = term_runtime.ex_term_tuple_length(result_word);
    if (descriptor_length != 2 and descriptor_length != 3) return false;
    const scale: f32 = if (descriptor_length == 2)
        1.0
    else blk: {
        const term = term_runtime.ex_term_tuple_get(result_word, 2);
        if (term_runtime.ex_term_is_integer(term) == 0) return false;
        const value = term_runtime.ex_term_to_int(term);
        if (value <= 0 or value > 1_000_000) return false;
        break :blk @floatFromInt(value);
    };

    var vertices: [16]u8 align(8) = undefined;
    var indices: [16]u8 align(8) = undefined;
    api.packed_vector3_array_constructor(&vertices, null);
    defer api.packed_vector3_array_destructor(&vertices);
    api.packed_int32_array_constructor(&indices, null);
    defer api.packed_int32_array_destructor(&indices);
    if (!fillPackedVector3Array(term_runtime.ex_term_tuple_get(result_word, 0), &vertices, scale) or
        !fillPackedInt32Array(term_runtime.ex_term_tuple_get(result_word, 1), &indices) or
        !resizeBuiltin(api.array_resize, arrays, mesh_array_slots)) return false;

    var vertices_variant: [24]u8 align(8) = undefined;
    var indices_variant: [24]u8 align(8) = undefined;
    api.packed_vector3_array_to_variant(&vertices_variant, &vertices);
    defer api.variant_destroy(&vertices_variant);
    api.packed_int32_array_to_variant(&indices_variant, &indices);
    defer api.variant_destroy(&indices_variant);
    return replaceArraySlot(arrays, mesh_array_vertex_slot, &vertices_variant) and
        replaceArraySlot(arrays, mesh_array_index_slot, &indices_variant);
}

fn replaceArraySlot(array: godot.TypePtr, index: i64, source: godot.ConstVariantPtr) bool {
    const destination = api.array_operator_index(array, index) orelse return false;
    api.variant_destroy(destination);
    api.variant_new_copy(destination, source);
    return true;
}

fn writeArrayMeshObjectResult(
    result_word: i64,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) void {
    const method_bind = array_mesh_add_surface_method orelse {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.object), "E_GODOT_OUTBOUND_CALL_UNDECLARED");
    };

    var class_name: [8]u8 align(8) = undefined;
    api.string_name_new_with_latin1_chars(&class_name, "ArrayMesh", 0);
    defer api.string_name_destructor(&class_name);
    const mesh = api.classdb_construct_object2(&class_name) orelse {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.object), "E_GODOT_INSTANCE_STATE_UNAVAILABLE");
    };

    var arrays: [8]u8 align(8) = undefined;
    var blend_shapes: [8]u8 align(8) = undefined;
    var lods: [8]u8 align(8) = undefined;
    api.array_constructor(&arrays, null);
    defer api.array_destructor(&arrays);
    api.array_constructor(&blend_shapes, null);
    defer api.array_destructor(&blend_shapes);
    api.dictionary_constructor(&lods, null);
    defer api.dictionary_destructor(&lods);
    if (!fillSurfaceArrays(result_word, &arrays)) {
        api.object_destroy(mesh);
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.object), "E_GODOT_PACKED_ARRAY_CODEC_MISSING");
    }

    var primitive: i64 = 3;
    var flags: i64 = 0;
    const arguments = [_]godot.ConstTypePtr{ &primitive, &arrays, &blend_shapes, &lods, &flags };
    api.object_method_bind_ptrcall(method_bind, mesh, &arguments, null);
    var object = mesh;
    api.object_to_variant(return_variant, @ptrCast(&object));
}

fn objectVariantToTerm(
    source: godot.VariantPtr,
    expected_class: []const u8,
    leases: *[max_method_arity]ObjectLease,
    lease_count: *usize,
    generation: u64,
) ?i64 {
    if (lease_count.* == max_method_arity) return null;
    var object: godot.ObjectPtr = null;
    api.object_from_variant(@ptrCast(&object), source);
    if (object == null or !objectMatchesClass(object, expected_class)) return null;

    const slot = lease_count.*;
    leases[slot] = .{ .object = object };
    lease_count.* += 1;
    const capability = ObjectCapability{
        .generation = generation,
        .slot = @intCast(slot),
        .guard = capabilityGuard(generation, @intCast(slot)),
    };
    const bytes = std.mem.asBytes(&capability);
    return term_runtime.ex_term_binary_from_bytes(bytes.ptr, bytes.len);
}

fn writeObjectResult(
    result_word: i64,
    expected_class: []const u8,
    leases: *const [max_method_arity]ObjectLease,
    lease_count: usize,
    generation: u64,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) void {
    if (term_runtime.ex_term_is_binary(result_word) == 0 or term_runtime.ex_term_binary_length(result_word) != @sizeOf(ObjectCapability)) {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.object), "E_GODOT_OBJECT_HANDLE_STALE");
    }
    var capability: ObjectCapability = undefined;
    const bytes = std.mem.asBytes(&capability);
    if (term_runtime.ex_term_binary_copy(result_word, bytes.ptr, bytes.len) != bytes.len or
        capability.generation != generation or
        capability.guard != capabilityGuard(capability.generation, capability.slot) or
        capability.slot >= lease_count)
    {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.object), "E_GODOT_OBJECT_HANDLE_STALE");
    }

    var object = leases[capability.slot].object;
    if (object == null or !objectMatchesClass(object, expected_class)) {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.object), "E_GODOT_OBJECT_HANDLE_STALE");
    }
    api.object_to_variant(return_variant, @ptrCast(&object));
}

fn objectMatchesClass(object: godot.ObjectPtr, expected_class: []const u8) bool {
    if (object == null or expected_class.len == 0 or expected_class.len >= method_name_storage_width) return false;
    var chars: [method_name_storage_width]u8 = undefined;
    @memcpy(chars[0..expected_class.len], expected_class);
    chars[expected_class.len] = 0;
    var class_name: [8]u8 align(8) = undefined;
    api.string_name_new_with_latin1_chars(&class_name, @ptrCast(chars[0..].ptr), 0);
    defer api.string_name_destructor(&class_name);
    const class_tag = api.classdb_get_class_tag(&class_name) orelse return false;
    return api.object_cast_to(object, class_tag) != null;
}

fn capabilityGuard(generation: u64, slot: u32) u32 {
    return @truncate(generation ^ (generation >> 32) ^ slot ^ 0xBA7A_7A0B);
}

fn textVariantToTerm(value_type: ValueType, source: godot.VariantPtr) ?i64 {
    var string_storage: [8]u8 align(8) = undefined;
    if (value_type == .string_value) {
        api.string_from_variant(&string_storage, source);
    } else {
        var string_name_storage: [8]u8 align(8) = undefined;
        api.string_name_from_variant(&string_name_storage, source);
        defer api.string_name_destructor(&string_name_storage);
        const arguments = [_]godot.ConstTypePtr{&string_name_storage};
        api.string_from_string_name(&string_storage, &arguments);
    }
    defer api.string_destructor(&string_storage);

    const length = api.string_to_utf8_chars(&string_storage, null, 0);
    if (length < 0) return null;
    if (length == 0) return term_runtime.ex_term_binary_from_bytes(null, 0);
    const memory = api.mem_alloc2(@intCast(length), 0) orelse return null;
    defer api.mem_free2(memory, 0);
    const bytes: [*]u8 = @ptrCast(memory);
    if (api.string_to_utf8_chars(&string_storage, bytes, length) != length) return null;
    return term_runtime.ex_term_binary_from_bytes(bytes, length);
}

fn writeTextResult(
    value_type: ValueType,
    result_word: i64,
    return_variant: godot.VariantPtr,
    call_error: *godot.CallError,
) void {
    const length = term_runtime.ex_term_binary_length(result_word);
    if (term_runtime.ex_term_is_binary(result_word) == 0 or length < 0) {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(variantType(value_type)), "E_GODOT_RETURN_TYPE_MISMATCH");
    }

    const capacity: usize = @intCast(length);
    const memory = api.mem_alloc2(@max(capacity, 1), 0) orelse {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(variantType(value_type)), "E_GODOT_STRING_CONVERSION_FAILED");
    };
    defer api.mem_free2(memory, 0);
    const bytes: [*]u8 = @ptrCast(memory);
    if (term_runtime.ex_term_binary_copy(result_word, bytes, length) != length) {
        return failCall(call_error, .invalid_method, -1, @intFromEnum(variantType(value_type)), "E_GODOT_STRING_CONVERSION_FAILED");
    }

    if (value_type == .string_value) {
        var string_storage: [8]u8 align(8) = undefined;
        if (api.string_new_with_utf8_chars_and_len2(&string_storage, bytes, length) != 0) {
            return failCall(call_error, .invalid_method, -1, @intFromEnum(godot.VariantType.string), "E_GODOT_STRING_INVALID_UTF8");
        }
        defer api.string_destructor(&string_storage);
        api.string_to_variant(return_variant, &string_storage);
    } else {
        var string_name_storage: [8]u8 align(8) = undefined;
        api.string_name_new_with_utf8_chars_and_len(&string_name_storage, bytes, length);
        defer api.string_name_destructor(&string_name_storage);
        api.string_name_to_variant(return_variant, &string_name_storage);
    }
}

fn leaveRuntime() void {
    _ = term_runtime.ex_term_runtime_leave();
}

fn finishMethodCall(
    instance: *Instance,
    method: *const MethodRuntime,
    state_word: i64,
    call_error: *godot.CallError,
) void {
    if (call_error.error_code != .ok or method.spec.state == .none) {
        leaveRuntime();
        return;
    }

    const result_handle = term_runtime.ex_term_result_create(instance.runtime_handle, state_word);
    if (result_handle <= 0) {
        leaveRuntime();
        return switch (result_handle) {
            -1 => failCall(call_error, .invalid_method, -1, 0, "E_GODOT_EDITOR_STATE_PIN_UNINITIALIZED"),
            -2 => failCall(call_error, .invalid_method, -1, 0, "E_GODOT_EDITOR_STATE_PIN_OOM"),
            -3 => failCall(call_error, .invalid_method, -1, 0, "E_GODOT_EDITOR_STATE_PIN_DUPLICATE"),
            else => failCall(call_error, .invalid_method, -1, 0, "E_GODOT_EDITOR_STATE_PIN_EXHAUSTED"),
        };
    }
    if (term_runtime.ex_term_runtime_leave() != 0) {
        return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_EDITOR_STATE_LEAVE_FAILED");
    }

    const exported = term_runtime.ex_term_export(result_handle, state_word);
    const destroyed = term_runtime.ex_term_result_destroy(result_handle);
    const replacement_runtime = term_runtime.ex_term_runtime_create();
    if (exported <= 0 or destroyed != 0 or replacement_runtime <= 0) {
        if (exported > 0) _ = term_runtime.ex_term_exported_destroy(exported);
        if (replacement_runtime > 0) _ = term_runtime.ex_term_runtime_destroy(replacement_runtime);
        instance.runtime_handle = 0;
        return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_EDITOR_STATE_EXPORT_FAILED");
    }

    if (instance.portable_state > 0 and
        term_runtime.ex_term_exported_destroy(instance.portable_state) != 0)
    {
        _ = term_runtime.ex_term_exported_destroy(exported);
        _ = term_runtime.ex_term_runtime_destroy(replacement_runtime);
        instance.runtime_handle = 0;
        return failCall(call_error, .invalid_method, -1, 0, "E_GODOT_EDITOR_STATE_STALE");
    }

    instance.runtime_handle = replacement_runtime;
    instance.portable_state = exported;
    instance.generation +%= 1;
}

fn failCall(call_error: *godot.CallError, error_code: godot.CallErrorType, argument: i32, expected: i32, comptime message: [:0]const u8) void {
    call_error.* = .{ .error_code = error_code, .argument = argument, .expected = expected };
    api.print_error(message.ptr, "Batata.Godot.methodCall", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
}

fn getVirtualCallData(
    class_userdata: ?*anyopaque,
    name: godot.ConstStringNamePtr,
    hash: u32,
) callconv(.c) ?*anyopaque {
    _ = class_userdata;
    _ = hash;
    for (&virtual_runtimes) |*virtual_runtime| {
        if (stringNameEquals(name, virtual_runtime.spec.name)) return virtual_runtime;
    }
    return null;
}

fn callVirtualWithData(
    class_instance: godot.ClassInstancePtr,
    name: godot.ConstStringNamePtr,
    virtual_userdata: ?*anyopaque,
    raw_arguments: ?[*]const godot.ConstTypePtr,
    return_value: godot.TypePtr,
) callconv(.c) void {
    _ = name;
    _ = return_value;
    if (std.Thread.getCurrentId() != initialization_thread) {
        return api.print_error("E_GODOT_WRONG_THREAD", "Batata.Godot.callVirtualWithData", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
    }
    const instance_opaque = class_instance orelse {
        return api.print_error("E_GODOT_OBJECT_HANDLE_STALE", "Batata.Godot.callVirtualWithData", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
    };
    const instance: *Instance = @ptrCast(@alignCast(instance_opaque));
    if (instance.magic != instance_magic or instance.runtime_handle <= 0) {
        return api.print_error("E_GODOT_OBJECT_HANDLE_STALE", "Batata.Godot.callVirtualWithData", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
    }
    const runtime_opaque = virtual_userdata orelse return;
    const virtual_runtime: *const MethodRuntime = @ptrCast(@alignCast(runtime_opaque));

    const runtime_handle = instance.runtime_handle;
    if (term_runtime.ex_term_runtime_enter(runtime_handle) != 0) {
        return api.print_error("E_GODOT_RUNTIME_BUSY", "Batata.Godot.callVirtualWithData", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
    }
    defer leaveRuntime();

    var arguments = [_]i64{nil_word} ** max_method_arity;
    if (virtual_runtime.spec.arity == 1) {
        const argument_pointers = raw_arguments orelse {
            return api.print_error("E_GODOT_METHOD_ARGUMENT_MISSING", "Batata.Godot.callVirtualWithData", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
        };
        const raw_delta = argument_pointers[0] orelse {
            return api.print_error("E_GODOT_METHOD_ARGUMENT_MISSING", "Batata.Godot.callVirtualWithData", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
        };
        const delta: *const f64 = @ptrCast(@alignCast(raw_delta));
        arguments[0] = term_runtime.ex_term_float_lit(@bitCast(delta.*));
    }

    const invocation = InvocationContext{ .method = virtual_runtime, .arguments = &arguments };
    var caught: i64 = 0;
    var exception_kind: i64 = 0;
    const encoded_context: i64 = @bitCast(@as(u64, @intFromPtr(&invocation)));
    const result = term_runtime.ex_term_protected_call(&invokeProtected, encoded_context, &caught, &exception_kind);
    if (caught != 0) {
        return api.print_error("E_GODOT_COMPILED_EXCEPTION", "Batata.Godot.callVirtualWithData", "packages/batata_godot/native/zig-src/main.zig", @intCast(exception_kind), 0);
    }
    if (result != nil_word) {
        return api.print_error("E_GODOT_RETURN_TYPE_MISMATCH", "Batata.Godot.callVirtualWithData", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
    }
}

fn stringNameEquals(name: godot.ConstStringNamePtr, expected: []const u8) bool {
    const source = name orelse return false;
    var string_storage: [8]u8 align(8) = undefined;
    const arguments = [_]godot.ConstTypePtr{source};
    api.string_from_string_name(&string_storage, &arguments);
    defer api.string_destructor(&string_storage);
    const length = api.string_to_utf8_chars(&string_storage, null, 0);
    if (length < 0 or length != expected.len or length >= method_name_storage_width) return false;
    var bytes: [method_name_storage_width]u8 = undefined;
    if (length != 0 and api.string_to_utf8_chars(&string_storage, &bytes, length) != length) return false;
    return std.mem.eql(u8, bytes[0..@intCast(length)], expected);
}

fn resolveOutboundMethodBinds() bool {
    if (!has_array_mesh_outbound) return true;
    var class_name: [8]u8 align(8) = undefined;
    var method_name: [8]u8 align(8) = undefined;
    api.string_name_new_with_latin1_chars(&class_name, "ArrayMesh", 0);
    defer api.string_name_destructor(&class_name);
    api.string_name_new_with_latin1_chars(&method_name, "add_surface_from_arrays", 0);
    defer api.string_name_destructor(&method_name);
    array_mesh_add_surface_method = api.classdb_get_method_bind(&class_name, &method_name, 1_796_411_378);
    return array_mesh_add_surface_method != null;
}

fn initialize(userdata: ?*anyopaque, level: godot.InitializationLevel) callconv(.c) void {
    _ = userdata;
    if (level != build_options.initialization_level or class_registered) return;
    initialization_thread = std.Thread.getCurrentId();

    api.string_name_new_with_latin1_chars(&class_name_storage, @ptrCast(class_name_z.ptr), 1);
    api.string_name_new_with_latin1_chars(&base_class_name_storage, @ptrCast(base_class_name_z.ptr), 1);
    api.string_name_new_with_latin1_chars(&empty_string_name_storage, "", 1);
    api.string_new_with_utf8_chars(&empty_string_storage, "");
    if (!resolveOutboundMethodBinds()) {
        api.print_error("E_GODOT_OUTBOUND_CALL_UNDECLARED", "Batata.Godot.initialize", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
        return;
    }

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
        .get_virtual_call_data_func = if (virtual_specs.len == 0) null else &getVirtualCallData,
        .call_virtual_with_data_func = if (virtual_specs.len == 0) null else &callVirtualWithData,
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

    for (property_specs, 0..) |property, index| {
        initializeStoredStringName(
            &property_name_storage[index],
            &property_name_chars[index],
            property.name,
        );
        initializeStoredStringName(
            &property_getter_storage[index],
            &property_getter_chars[index],
            property.getter,
        );
        initializeStoredStringName(
            &property_setter_storage[index],
            &property_setter_chars[index],
            property.setter,
        );
        var info = propertyInfo(property.value_type);
        info.name = &property_name_storage[index];
        api.classdb_register_extension_class_property(
            library,
            &class_name_storage,
            &info,
            &property_setter_storage[index],
            &property_getter_storage[index],
        );
    }

    for (signal_specs, 0..) |signal, index| {
        initializeStoredStringName(&signal_name_storage[index], &signal_name_chars[index], signal.name);
        var arguments: [max_method_arity]godot.PropertyInfo = undefined;
        for (0..signal.arity) |argument_index| {
            arguments[argument_index] = propertyInfo(signal.arguments[argument_index]);
        }
        api.classdb_register_extension_class_signal(
            library,
            &class_name_storage,
            &signal_name_storage[index],
            if (signal.arity == 0) null else arguments[0..signal.arity].ptr,
            @intCast(signal.arity),
        );
    }
    class_registered = true;
}

fn initializeStoredStringName(
    storage: *[8]u8,
    chars: *[method_name_storage_width]u8,
    value: []const u8,
) void {
    @memcpy(chars[0..value.len], value);
    chars[value.len] = 0;
    api.string_name_new_with_latin1_chars(storage, @ptrCast(chars[0..].ptr), 1);
}

fn deinitialize(userdata: ?*anyopaque, level: godot.InitializationLevel) callconv(.c) void {
    _ = userdata;
    if (level != build_options.initialization_level or !class_registered) return;
    if (live_instances.load(.acquire) != 0) {
        api.print_error("E_GODOT_RUNTIME_BUSY", "Batata.Godot.deinitialize", "packages/batata_godot/native/zig-src/main.zig", 0, 0);
    }
    api.classdb_unregister_extension_class(library, &class_name_storage);
    api.string_destructor(&empty_string_storage);
    array_mesh_add_surface_method = null;
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
