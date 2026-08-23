const runtime = @import("term_runtime");

const Namespace = struct {
    pub const value = 42;
};

fn symbol(comptime name: []const u8) ?[]const u8 {
    return if (name.len > 0) "value" else null;
}

comptime {
    _ = runtime.Extension(.{ .namespace = Namespace, .symbol = symbol });
}
