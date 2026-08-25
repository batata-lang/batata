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
    module.addCSourceFile(.{
        .file = b.path("native/appkit-protocol.m"),
        .flags = &.{},
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
        .file = b.path("native/appkit-protocol.m"),
        .flags = &.{},
    });
    tests.root_module.addCSourceFile(.{
        .file = b.path("native/test/exception-probe.m"),
        .flags = &.{"-fobjc-exceptions"},
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Objective-C ABI and ownership tests");
    test_step.dependOn(&run_tests.step);

    const batata_object = b.option([]const u8, "batata-object", "Path to the compiled Batata object");
    const runtime_library = b.option([]const u8, "runtime-library", "Path to the Batata term runtime archive");
    const term_runtime_source = b.option([]const u8, "term-runtime-source", "Path to term_runtime.zig");
    if (batata_object != null and runtime_library != null and term_runtime_source != null) {
        addAppKitApplication(b, target, optimize, batata_object.?, runtime_library.?, term_runtime_source.?);
    }
}

fn addAppKitApplication(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    batata_object: []const u8,
    runtime_library: []const u8,
    term_runtime_source: []const u8,
) void {
    const app_name = b.option([]const u8, "app-name", "Application name") orelse "BatataHello";
    const options = b.addOptions();
    options.addOption([]const u8, "app_name", app_name);
    options.addOption([]const u8, "window_title", b.option([]const u8, "window-title", "Window title") orelse "Batata AppKit");
    options.addOption([]const u8, "label_text", b.option([]const u8, "label-text", "Label text") orelse "Ready");
    options.addOption([]const u8, "button_title", b.option([]const u8, "button-title", "Button title") orelse "Run Batata");
    options.addOption([]const u8, "did_finish_symbol", b.option([]const u8, "did-finish-symbol", "Batata launch callback symbol") orelse @panic("missing -Ddid-finish-symbol"));
    options.addOption([]const u8, "button_symbol", b.option([]const u8, "button-symbol", "Batata button callback symbol") orelse @panic("missing -Dbutton-symbol"));
    options.addOption([]const u8, "should_terminate_symbol", b.option([]const u8, "should-terminate-symbol", "Batata termination callback symbol") orelse @panic("missing -Dshould-terminate-symbol"));
    options.addOption(i64, "true_word", b.option(i64, "true-word", "Batata true atom word") orelse @panic("missing -Dtrue-word"));
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run the deterministic AppKit callback smoke") orelse false);
    inline for (.{ "window-x", "window-y", "window-width", "window-height", "label-x", "label-y", "label-width", "label-height", "button-x", "button-y", "button-width", "button-height" }) |name| {
        options.addOption(f64, std.mem.replaceOwned(u8, b.allocator, name, "-", "_") catch @panic("out of memory"), b.option(f64, name, name) orelse @panic("missing AppKit frame option"));
    }

    const term_runtime = b.createModule(.{
        .root_source_file = .{ .cwd_relative = term_runtime_source },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const objc_runtime = b.createModule(.{
        .root_source_file = b.path("native/zig-src/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const executable = b.addExecutable(.{
        .name = app_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/zig-src/appkit.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    executable.use_lld = false;
    executable.root_module.addImport("term_runtime", term_runtime);
    executable.root_module.addImport("objc_runtime", objc_runtime);
    executable.root_module.addOptions("build_options", options);
    executable.root_module.addObjectFile(.{ .cwd_relative = batata_object });
    executable.root_module.addObjectFile(.{ .cwd_relative = runtime_library });
    executable.root_module.addCSourceFile(.{
        .file = b.path("native/objc-exception.m"),
        .flags = &.{"-fobjc-exceptions"},
    });
    executable.root_module.addCSourceFile(.{
        .file = b.path("native/appkit-protocol.m"),
        .flags = &.{},
    });
    configureAppleModule(b, executable.root_module);

    const install = b.addInstallArtifact(executable, .{});
    const step = b.step("appkit-app", "Build the Batata AppKit executable");
    step.dependOn(&install.step);
}

fn configureAppleModule(b: *std.Build, module: *std.Build.Module) void {
    if (b.sysroot) |sysroot| {
        module.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
        module.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
    }
    module.linkSystemLibrary("objc", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("AppKit", .{});
}
