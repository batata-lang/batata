const runtime = @import("term_runtime");

const Namespace = struct {
    pub fn entry() callconv(.c) void {}
};

fn symbol() ?[]const u8 {
    return "entry";
}

comptime {
    _ = runtime.Extension(.{ .namespace = Namespace, .symbol = symbol });
}
