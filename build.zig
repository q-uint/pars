const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Embed stdlib .pars sources as compile-time constants so vm.zig can
    // pre-load them without @embedFile crossing the module boundary.
    const stdlib_opts = b.addOptions();
    stdlib_opts.addOption([]const u8, "abnf", @embedFile("lib/abnf.pars"));
    stdlib_opts.addOption([]const u8, "pars", @embedFile("lib/pars.pars"));

    // Also install the stdlib sources to share/pars/lib so editor tooling
    // (the LSP) can return file:// locations into them for goto-definition
    // and hover. The compiler itself uses the embedded copies above.
    const stdlib_install = b.addInstallDirectory(.{
        .source_dir = b.path("lib"),
        .install_dir = .prefix,
        .install_subdir = "share/pars/lib",
    });
    b.getInstallStep().dependOn(&stdlib_install.step);

    // Paths baked into the LSP binary for stdlib discovery. The source
    // path is used in dev/test builds (where the exe is not installed);
    // the install path is used in installed builds; both are fallbacks
    // behind $PARS_STDLIB_PATH and exe-relative discovery.
    const lsp_opts = b.addOptions();
    lsp_opts.addOption([]const u8, "stdlib_source_path", b.pathFromRoot("lib"));
    lsp_opts.addOption([]const u8, "stdlib_install_path", b.getInstallPath(.prefix, "share/pars/lib"));
    const lsp_opts_mod = lsp_opts.createModule();

    const mod = b.addModule("pars", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("pars_stdlib", stdlib_opts.createModule());

    const exe = b.addExecutable(.{
        .name = "pars",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pars", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const lsp_mod = b.createModule(.{
        .root_source_file = b.path("tools/lsp/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pars", .module = mod },
            .{ .name = "lsp_build_opts", .module = lsp_opts_mod },
        },
    });
    const lsp_exe = b.addExecutable(.{
        .name = "pars-lsp",
        .root_module = lsp_mod,
    });
    b.installArtifact(lsp_exe);

    const lsp_server_mod = b.createModule(.{
        .root_source_file = b.path("tools/lsp/server.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "pars", .module = mod },
            .{ .name = "lsp_build_opts", .module = lsp_opts_mod },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const lsp_tests = b.addTest(.{
        .root_module = lsp_server_mod,
    });
    const run_lsp_tests = b.addRunArtifact(lsp_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_lsp_tests.step);
}
