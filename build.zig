const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const runtime_module = b.addModule("term_runtime", .{
        .root_source_file = b.path("native/term_runtime.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addRuntimeArtifact(b, target, optimize, runtime_module, .dynamic, "term-runtime-shared");
    addRuntimeArtifact(b, target, optimize, runtime_module, .static, "term-runtime-static");

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/term_runtime.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test-runtime", "Run the Zig term runtime unit tests");
    test_step.dependOn(&run_unit_tests.step);

    addContractTests(b);
}

fn addRuntimeArtifact(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    runtime_module: *std.Build.Module,
    linkage: std.builtin.LinkMode,
    step_name: []const u8,
) void {
    const library = b.addLibrary(.{
        .name = "term_runtime",
        .linkage = linkage,
        .root_module = b.createModule(.{
            .root_source_file = b.path("native/term_runtime_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = if (linkage == .static) true else null,
            .stack_check = if (linkage == .static) false else null,
        }),
    });
    library.root_module.addImport("term_runtime", runtime_module);

    const install = b.addInstallArtifact(library, .{
        .dest_dir = .{ .override = .lib },
    });
    const step = b.step(step_name, "Build and install a Batata term runtime library");
    step.dependOn(&install.step);
}

fn addContractTests(b: *std.Build) void {
    const contract_tests = b.step("test-contracts", "Verify compile-time extension diagnostics");
    const fixtures = [_]struct {
        path: []const u8,
        diagnostic: []const u8,
    }{
        .{
            .path = "native/compile_fail/extension_missing_field.zig",
            .diagnostic = "TermRuntime.Extension spec is missing required field .symbol",
        },
        .{
            .path = "native/compile_fail/extension_invalid_function.zig",
            .diagnostic = "TermRuntime.Extension declaration value must be a function",
        },
        .{
            .path = "native/compile_fail/extension_invalid_mapper.zig",
            .diagnostic = "TermRuntime.Extension .symbol must be fn(comptime []const u8) ?[]const u8",
        },
        .{
            .path = "native/compile_fail/extension_empty_symbol.zig",
            .diagnostic = "TermRuntime.Extension symbol for entry must not be empty",
        },
        .{
            .path = "native/compile_fail/extension_invalid_calling_convention.zig",
            .diagnostic = "TermRuntime.Extension declaration entry must use the C calling convention",
        },
        .{
            .path = "native/compile_fail/extension_duplicate_symbol.zig",
            .diagnostic = "TermRuntime.Extension duplicate external symbol: duplicate",
        },
    };

    inline for (fixtures) |fixture| {
        const compile = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build-obj",
            "-fno-emit-bin",
            "--dep",
            "term_runtime",
        });
        compile.addPrefixedFileArg("-Mroot=", b.path(fixture.path));
        compile.addPrefixedFileArg("-Mterm_runtime=", b.path("native/term_runtime.zig"));
        compile.expectExitCode(1);
        compile.expectStdErrMatch(fixture.diagnostic);
        contract_tests.dependOn(&compile.step);
    }
}
