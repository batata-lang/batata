const runtime = @import("term_runtime");

const Namespace = struct {
    pub fn first() callconv(.c) void {}
    pub fn second() callconv(.c) void {}
};

fn symbol(comptime name: []const u8) ?[]const u8 {
    return if (name.len > 0) "duplicate" else null;
}

comptime {
    _ = runtime.Extension(.{ .namespace = Namespace, .symbol = symbol });
}
