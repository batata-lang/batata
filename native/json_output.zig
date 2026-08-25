const std = @import("std");

/// Writes one minified JSON value with an optional protocol prefix.
pub fn write(writer: *std.Io.Writer, prefix: []const u8, value: anytype) !void {
    try writer.writeAll(prefix);
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

/// Serializes one JSON line to stderr while coordinating with Zig diagnostics.
pub fn writeStderr(prefix: []const u8, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    try write(&stderr.file_writer.interface, prefix, value);
}

test "writes prefixed JSON with escaped string fields" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write(&writer, "BATATA_TEST ", .{
        .enabled = true,
        .name = "quote\" newline\n",
        .values = [_]u16{ 1, 2 },
    });

    try std.testing.expectEqualStrings(
        "BATATA_TEST {\"enabled\":true,\"name\":\"quote\\\" newline\\n\",\"values\":[1,2]}\n",
        writer.buffered(),
    );
}
