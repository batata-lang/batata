const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const entry_symbol = b.option([]const u8, "entry-symbol", "GDExtension entry symbol") orelse
        @panic("missing required -Dentry-symbol");
    const initialization_level = b.option(u8, "initialization-level", "Godot initialization level") orelse
        @panic("missing required -Dinitialization-level");
    const class_name = b.option([]const u8, "class-name", "Godot extension class name") orelse
        @panic("missing required -Dclass-name");
    const base_class_name = b.option([]const u8, "base-class-name", "Godot extension base class name") orelse
        @panic("missing required -Dbase-class-name");
    const term_runtime_source = b.option([]const u8, "term-runtime-source", "Path to term_runtime.zig") orelse
        @panic("missing required -Dterm-runtime-source");
    const batata_object = b.option([]const u8, "batata-object", "Path to the compiled Batata object") orelse
        @panic("missing required -Dbatata-object");
    const runtime_library = b.option([]const u8, "runtime-library", "Path to the Batata runtime archive") orelse
        @panic("missing required -Druntime-library");
    const library_name = b.option([]const u8, "library-name", "Installed extension library name") orelse
        @panic("missing required -Dlibrary-name");

    const options = b.addOptions();
    options.addOption([]const u8, "entry_symbol", entry_symbol);
    options.addOption(u8, "initialization_level", initialization_level);
    options.addOption([]const u8, "class_name", class_name);
    options.addOption([]const u8, "base_class_name", base_class_name);

    const term_runtime = b.createModule(.{
        .root_source_file = .{ .cwd_relative = term_runtime_source },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const library = b.addLibrary(.{
        .name = library_name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/zig-src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    library.root_module.addImport("term_runtime", term_runtime);
    library.root_module.addOptions("build_options", options);
    library.root_module.addObjectFile(.{ .cwd_relative = batata_object });
    library.root_module.addObjectFile(.{ .cwd_relative = runtime_library });
    library.root_module.addRPathSpecial("@loader_path");

    const install = b.addInstallArtifact(library, .{
        .dest_dir = .{ .override = .lib },
    });
    const step = b.step("godot-extension", "Build and install the Batata GDExtension");
    step.dependOn(&install.step);
}
