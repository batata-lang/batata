const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .root_source_file = b.path("native/zig-src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (b.sysroot) |sysroot| {
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
    }
    module.linkSystemLibrary("objc", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("AppKit", .{});
    module.addCSourceFile(.{
        .file = b.path("native/objc-exception.m"),
        .flags = &.{"-fobjc-exceptions"},
    });

    const library = b.addLibrary(.{
        .name = "batata_objc",
        .linkage = .static,
        .root_module = module,
    });
    const install = b.addInstallArtifact(library, .{});
    const library_step = b.step("objc-runtime", "Build the fixed Objective-C runtime adapter");
    library_step.dependOn(&install.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/zig-src/runtime.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (b.sysroot) |sysroot| {
        tests.root_module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        tests.root_module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
    }
    tests.root_module.linkSystemLibrary("objc", .{});
    tests.root_module.linkFramework("Foundation", .{});
    tests.root_module.linkFramework("AppKit", .{});
    tests.root_module.addCSourceFile(.{
        .file = b.path("native/objc-exception.m"),
        .flags = &.{"-fobjc-exceptions"},
    });
    tests.root_module.addCSourceFile(.{
        .file = b.path("native/test/exception-probe.m"),
        .flags = &.{"-fobjc-exceptions"},
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Objective-C ABI and ownership tests");
    test_step.dependOn(&run_tests.step);
}
