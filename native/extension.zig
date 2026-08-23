//! Compile-time materialization of native host extension entry points.
//!
//! An extension supplies a namespace and a symbol mapper. The mapper returns
//! the external symbol for declarations that belong to the extension and null
//! for every other declaration. The complete surface is validated before any
//! symbol is exported, so malformed adapters fail during Zig compilation.

const std = @import("std");

pub fn Extension(comptime spec: anytype) type {
    const Spec = @TypeOf(spec);

    comptime {
        @setEvalBranchQuota(10_000_000);

        for (.{ "namespace", "symbol" }) |field| {
            if (!@hasField(Spec, field)) {
                @compileError("TermRuntime.Extension spec is missing required field ." ++ field);
            }
        }

        if (@TypeOf(spec.namespace) != type) {
            @compileError("TermRuntime.Extension .namespace must be a type");
        }

        const SymbolMapper = fn (comptime []const u8) ?[]const u8;
        if (@TypeOf(spec.symbol) != SymbolMapper) {
            @compileError("TermRuntime.Extension .symbol must be fn(comptime []const u8) ?[]const u8");
        }

        switch (@typeInfo(spec.namespace)) {
            .@"struct" => {},
            else => @compileError("TermRuntime.Extension .namespace must be a struct namespace"),
        }

        var export_count: usize = 0;
        const declarations = @typeInfo(spec.namespace).@"struct".decls;

        for (declarations, 0..) |declaration, index| {
            const external_name = spec.symbol(declaration.name) orelse continue;
            export_count += 1;
            validateSymbol(external_name, declaration.name);
            validateFunction(@TypeOf(@field(spec.namespace, declaration.name)), declaration.name);

            for (declarations[0..index]) |previous| {
                const previous_name = spec.symbol(previous.name) orelse continue;
                if (std.mem.eql(u8, external_name, previous_name)) {
                    @compileError("TermRuntime.Extension duplicate external symbol: " ++ external_name);
                }
            }
        }

        if (export_count == 0) {
            @compileError("TermRuntime.Extension selected no exported declarations");
        }

        if (@hasField(Spec, "validate")) {
            if (@TypeOf(spec.validate) != fn () void) {
                @compileError("TermRuntime.Extension .validate must be fn() void");
            }
            spec.validate();
        }
    }

    return struct {
        comptime {
            @setEvalBranchQuota(100_000);
            for (@typeInfo(spec.namespace).@"struct".decls) |declaration| {
                const external_name = spec.symbol(declaration.name) orelse continue;
                @export(&@field(spec.namespace, declaration.name), .{ .name = external_name });
            }
        }
    };
}

fn validateSymbol(comptime external_name: []const u8, comptime declaration_name: []const u8) void {
    if (external_name.len == 0) {
        @compileError("TermRuntime.Extension symbol for " ++ declaration_name ++ " must not be empty");
    }
    if (std.mem.indexOfScalar(u8, external_name, 0) != null) {
        @compileError("TermRuntime.Extension symbol for " ++ declaration_name ++ " must not contain NUL");
    }
}

fn validateFunction(comptime Function: type, comptime declaration_name: []const u8) void {
    const function_info = switch (@typeInfo(Function)) {
        .@"fn" => |info| info,
        else => @compileError("TermRuntime.Extension declaration " ++ declaration_name ++ " must be a function"),
    };

    if (!std.meta.eql(function_info.calling_convention, std.builtin.CallingConvention.c)) {
        @compileError("TermRuntime.Extension declaration " ++ declaration_name ++ " must use the C calling convention");
    }
}
