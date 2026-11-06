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
    const goose = try b.dependencyLazy("goose", .{
        .target = target,
        .optimize = optimize,
    });
    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const config_mod = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "known_folders", .module = known_folders.module("known-folders") },
        },
    });

    const core_platform_root = switch (target.result.os.tag) {
        .linux => b.path("src/core/linux/root.zig"),
        .windows => b.path("src/core/windows/root.zig"),
        .macos => b.path("src/core/macos/root.zig"),
        else => b.path("src/core/windows/root.zig"),
    };

    const core_types = b.addModule("core_types", .{
        .root_source_file = b.path("src/core/types.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    const core_platform = b.addModule("core_platform", .{
        .root_source_file = core_platform_root,
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = switch (target.result.os.tag) {
            .linux => &.{
                .{ .name = "goose", .module = goose.module("goose") },
                .{ .name = "core_types", .module = core_types },
                .{ .name = "config", .module = config_mod },
            },
            .windows, .macos => &.{
                .{ .name = "core_types", .module = core_types },
                .{ .name = "config", .module = config_mod },
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
        .root_source_file = b.path("src/model/model.zig"),
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
        .root_source_file = b.path("src/downloader/download.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "model", .module = model_mod },
        },
    });

    const kocr_mod = b.addModule("kocr", .{
        .root_source_file = b.path("src/root.zig"),
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
        .root_source_file = b.path("src/main.zig"),
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
    const gui_root = switch (target.result.os.tag) {
        .linux => b.path("src/gui/linux.zig"),
        .windows => b.path("src/gui/windows.zig"),
        .macos => b.path("src/gui/macos.zig"),
        else => {
            const fail = b.addFail("kocr-gui supports Linux, Windows, and macOS only");
            const gui_step = b.step("gui", "Build the native GUI");
            gui_step.dependOn(&fail.step);
            return;
        },
    };

    const gui_mod = b.createModule(.{
        .root_source_file = gui_root,
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

    switch (target.result.os.tag) {
        .linux => {
            const qt6 = try b.dependencyLazy("qt6", .{
                .target = target,
                .optimize = optimize,
            });
            const qt6_build = b.lazyImport(@This(), "qt6") orelse
                return error.LazyDependencyNeeded;
            gui_mod.addImport("libqt6zig", qt6.module("libqt6zig"));
            for (qt_libs) |lib| gui.root_module.linkLibrary(qt6.artifact(lib));
            try qt6_build.configureQtExeRootModule(b, gui, .{});

            const install_gui = b.addInstallArtifact(gui, .{});
            const gui_step = b.step("gui", "Build the Linux Qt6 GUI");
            gui_step.dependOn(&install_gui.step);

            const gui_cmd = b.addRunArtifact(gui);
            gui_cmd.step.dependOn(&install_gui.step);
            gui_cmd.addPassthruArgs();
            const gui_run = b.step("run-gui", "Run the Linux Qt6 GUI");
            gui_run.dependOn(&gui_cmd.step);
        },
        .windows => {
            const win32 = try b.dependencyLazy("win32", .{});
            gui_mod.addImport("win32", win32.module("win32"));
            gui.subsystem = .windows;
            addGuiStep(b, gui);
        },
        .macos => {
            const objc = try b.dependencyLazy("objc", .{
                .target = target,
                .optimize = optimize,
            });
            gui_mod.addImport("objc", objc.module("objc"));
            addGuiStep(b, gui);
        },
        else => unreachable,
    }
}

fn addGuiStep(b: *std.Build, gui: *std.Build.Step.Compile) void {
    const gui_step = b.step("gui", "Build the native GUI");
    gui_step.dependOn(&b.addInstallArtifact(gui, .{}).step);
}

const qt_libs = [_][]const u8{
    "qabstractbutton",
    "qapplication",
    "qguiapplication",
    "qboxlayout",
    "qclipboard",
    "qcombobox",
    "qfiledialog",
    "qkeysequenceedit",
    "qdialog",
    "qcheckbox",
    "qobject",
    "qsize",
    "qkeysequence",
    "qlayout",
    "qlabel",
    "qabstractitemview",
    "qlineedit",
    "qlistview",
    "qlistwidget",
    "qplaintextedit",
    "qpushbutton",
    "qpalette",
    "qpixmap",
    "qsplitter",
    "qtimer",
    "qwidget",
};

comptime {
    const minimum = std.SemanticVersion.parse("0.17.1") catch unreachable;

    if (builtin.zig_version.order(minimum) == .lt) {
        @compileError(std.fmt.comptimePrint(
            \\Your version of Zig is too old.
            \\Minimum required version: 0.17.1
        , .{}));
    }
}
