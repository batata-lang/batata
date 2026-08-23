//! Standalone shared/static library root for Batata's term runtime ABI.

const std = @import("std");
const runtime = @import("term_runtime");

fn runtimeSymbol(comptime declaration_name: []const u8) ?[]const u8 {
    const prefix = "ex_term_";
    if (!std.mem.startsWith(u8, declaration_name, prefix)) return null;
    return "ex.term." ++ declaration_name[prefix.len..];
}

const exports = runtime.Extension(.{
    .namespace = runtime,
    .symbol = runtimeSymbol,
});

comptime {
    _ = exports;
}
