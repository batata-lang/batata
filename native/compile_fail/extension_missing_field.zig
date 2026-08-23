const runtime = @import("term_runtime");

comptime {
    _ = runtime.Extension(.{ .namespace = struct {} });
}
