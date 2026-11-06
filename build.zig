const std = @import("std");
const builtin = @import("builtin");

const zommand = @import("zommand");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const x86_isa = b.option([]const u8, "x86_isa", "x86 dispatch subset: all, off, or comma-separated ISAs") orelse "avx,avx2,avx512";
    const arm_isa = b.option([]const u8, "arm_isa", "arm64 dispatch subset: all, off, or comma-separated ISAs") orelse "all";

    const ncnn = b.dependency("ncnn", .{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .x86_isa = x86_isa,
        .arm_isa = arm_isa,
    });
    const zignal = b.dependency("zignal", .{
        .target = target,
        .optimize = optimize,
    });
    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });
    const goose = if (target.result.os.tag == .linux)
        try b.dependencyLazy("goose", .{
            .target = target,
            .optimize = optimize,
        })
    else
        null;
    const win32 = if (target.result.os.tag == .windows)
        try b.dependencyLazy("win32", .{})
    else
        null;
    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/core/config.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "known_folders", .module = known_folders.module("known-folders") },
        },
    });

    const core_types = b.addModule("core_types", .{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const core_platform = b.addModule("core_platform", .{
        .root_source_file = b.path("src/core/platforms/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = switch (target.result.os.tag) {
            .linux => &.{
                .{ .name = "core_types", .module = core_types },
                .{ .name = "config", .module = config_mod },
                .{ .name = "goose", .module = goose.?.module("goose") },
            },
            .windows => &.{
                .{ .name = "core_types", .module = core_types },
                .{ .name = "config", .module = config_mod },
                .{ .name = "win32", .module = win32.?.module("win32") },
                .{ .name = "zignal", .module = zignal.module("zignal") },
            },
            else => &.{
                .{ .name = "core_types", .module = core_types },
                .{ .name = "config", .module = config_mod },
            },
        },
    });

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "core_platform", .module = core_platform },
            .{ .name = "core_types", .module = core_types },
        },
    });

    const core_check = b.addObject(.{
        .name = "core-check",
        .root_module = core_mod,
    });
    const core_check_step = b.step("check-core", "Type-check the core module");
    core_check_step.dependOn(&core_check.step);

    const core_tests = b.addTest(.{
        .name = "core-tests",
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    const core_test_step = b.step("test-core", "Run core tests");
    core_test_step.dependOn(&run_core_tests.step);

    const model_mod = b.addModule("model", .{
        .root_source_file = b.path("src/core/model/model.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "ncnn", .module = ncnn.module("ncnn") },
            .{ .name = "zignal", .module = zignal.module("zignal") },
            .{ .name = "known_folders", .module = known_folders.module("known-folders") },
        },
    });

    const downloader_mod = b.addModule("downloader", .{
        .root_source_file = b.path("src/core/downloader/download.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "model", .module = model_mod },
        },
    });

    const kocr_mod = b.addModule("kocr", .{
        .root_source_file = b.path("src/core/lib.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = &.{
            .{ .name = "model", .module = model_mod },
            .{ .name = "downloader", .module = downloader_mod },
            .{ .name = "zignal", .module = zignal.module("zignal") },
            .{ .name = "zqlite", .module = zqlite.module("zqlite") },
        },
    });

    const kocr_tests = b.addTest(.{
        .name = "kocr-tests",
        .root_module = kocr_mod,
    });
    const run_kocr_tests = b.addRunArtifact(kocr_tests);
    const kocr_test_step = b.step("test-kocr", "Run OCR tests");
    kocr_test_step.dependOn(&run_kocr_tests.step);

    const cli = zommand.createCli(b, .{
        .target = target,
        .optimize = optimize,
        .schema = b.path("cli.zon"),
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "core", .module = core_mod },
            .{ .name = "kocr", .module = kocr_mod },
            .{ .name = "cli", .module = cli },
        },
    });

    const exe = b.addExecutable(.{
        .name = "kocr",
        .root_module = exe_mod,
    });
    if (target.result.os.tag == .windows) linkWindowsLibraries(exe);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run kocr");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    try addGui(b, target, optimize, strip, kocr_mod, core_mod, config_mod);
}

fn addGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    kocr_mod: *std.Build.Module,
    core_mod: *std.Build.Module,
    config_mod: *std.Build.Module,
) !void {
    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/app.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "config", .module = config_mod },
            .{ .name = "core", .module = core_mod },
            .{ .name = "kocr", .module = kocr_mod },
        },
    });
    gui_mod.link_libc = true;

    const gui = b.addExecutable(.{
        .name = "kocr-gui",
        .root_module = gui_mod,
    });

    const nanoui = if (target.result.os.tag == .windows)
        b.dependency("nanoui", .{
            .target = target,
            .optimize = optimize,
            .webview2 = "none",
        })
    else
        b.dependency("nanoui", .{
            .target = target,
            .optimize = optimize,
        });
    gui_mod.addImport("nanoui", nanoui.module("nanoui"));

    if (target.result.os.tag == .windows) {
        linkWindowsLibraries(gui);
        gui.subsystem = .windows;
    }
    addGuiStep(b, gui);
}

fn addGuiStep(b: *std.Build, gui: *std.Build.Step.Compile) void {
    const install_gui = b.addInstallArtifact(gui, .{});
    const gui_step = b.step("gui", "Build the native GUI");
    gui_step.dependOn(&install_gui.step);

    const gui_cmd = b.addRunArtifact(gui);
    gui_cmd.step.dependOn(&install_gui.step);
    gui_cmd.addPassthruArgs();
    const gui_run = b.step("run-gui", "Run the native GUI");
    gui_run.dependOn(&gui_cmd.step);
}

fn linkWindowsLibraries(artifact: *std.Build.Step.Compile) void {
    for ([_][]const u8{ "user32", "gdi32", "comctl32", "comdlg32", "advapi32" }) |lib| {
        artifact.root_module.linkSystemLibrary(lib, .{});
    }
}

comptime {
    const minimum = std.SemanticVersion.parse("0.17.1") catch unreachable;

    if (builtin.zig_version.order(minimum) == .lt) {
        @compileError(std.fmt.comptimePrint(
            \\Your version of Zig is too old.
            \\Minimum required version: 0.17.1
        , .{}));
    }
}
