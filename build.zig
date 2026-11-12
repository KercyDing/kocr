const std = @import("std");
const builtin = @import("builtin");

const bundler = @import("bundle");
const zommand = @import("zommand");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const format = b.option(bundler.Format, "format", "Bundle format") orelse null;
    const codesign_identity = b.option([]const u8, "codesign-identity", "macOS signing identity; defaults to ad-hoc") orelse "-";
    const x86_isa = b.option([]const u8, "x86_isa", "x86 dispatch subset: all, off, or comma-separated ISAs") orelse "avx,avx2,avx512";
    const arm_isa = b.option([]const u8, "arm_isa", "arm64 dispatch subset: all, off, or comma-separated ISAs") orelse "all";

    const ncnn = b.dependency("ncnn_zig", .{
        .target = target,
        .optimize = optimize,
        .x86_isa = x86_isa,
        .arm_isa = arm_isa,
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
    const zignal = b.dependency("zignal", .{
        .target = target,
        .optimize = optimize,
    });
    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });
    const zqlite = b.dependency("zqlite", .{
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

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = switch (target.result.os.tag) {
            .linux => &.{
                .{ .name = "ncnn", .module = ncnn.module("ncnn") },
                .{ .name = "zignal", .module = zignal.module("zignal") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
                .{ .name = "known_folders", .module = known_folders.module("known-folders") },
                .{ .name = "goose", .module = goose.?.module("goose") },
            },
            .windows => &.{
                .{ .name = "ncnn", .module = ncnn.module("ncnn") },
                .{ .name = "zignal", .module = zignal.module("zignal") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
                .{ .name = "known_folders", .module = known_folders.module("known-folders") },
                .{ .name = "win32", .module = win32.?.module("win32") },
            },
            else => &.{
                .{ .name = "ncnn", .module = ncnn.module("ncnn") },
                .{ .name = "zignal", .module = zignal.module("zignal") },
                .{ .name = "zqlite", .module = zqlite.module("zqlite") },
                .{ .name = "known_folders", .module = known_folders.module("known-folders") },
            },
        },
    });

    if (target.result.os.tag == .macos) {
        core_mod.linkFramework("Carbon", .{});
        core_mod.linkFramework("ServiceManagement", .{});
    }

    const core_tests = b.addTest(.{
        .name = "core-tests",
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    const core_test_step = b.step("test", "Run tests");
    core_test_step.dependOn(&run_core_tests.step);

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
            .{ .name = "core", .module = core_mod },
            .{ .name = "cli", .module = cli },
        },
    });

    const exe = b.addExecutable(.{
        .name = "kocr",
        .root_module = exe_mod,
    });
    if (target.result.os.tag == .windows) {
        linkWindowsLibraries(exe);
        exe_mod.addWin32ResourceFile(.{
            .file = b.path("src/gui/icons/kocr.rc"),
            .include_paths = &.{b.path("src/gui/icons")},
        });
    }

    const cli_install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&cli_install.step);
    const cli_step = b.step("cli", "Build the CLI");
    cli_step.dependOn(&cli_install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&cli_install.step);
    run_cmd.addPassthruArgs();
    const run_step = b.step("run-cli", "Run the CLI");
    run_step.dependOn(&run_cmd.step);

    const gui_mod = b.createModule(.{
        .root_source_file = b.path("src/gui/app.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
        .imports = if (target.result.os.tag == .windows) &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "nanoui", .module = nanoui.module("nanoui") },
            .{ .name = "win32", .module = win32.?.module("win32") },
        } else &.{
            .{ .name = "core", .module = core_mod },
            .{ .name = "nanoui", .module = nanoui.module("nanoui") },
        },
    });

    // The About window shows it; build.zig.zon keeps the one copy.
    const gui_options = b.addOptions();
    gui_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    gui_mod.addOptions("build_options", gui_options);

    const gui = b.addExecutable(.{
        .name = "kocr-gui",
        .root_module = gui_mod,
    });

    if (target.result.os.tag == .windows) {
        linkWindowsLibraries(gui);
        gui.subsystem = .windows;
        gui_mod.addWin32ResourceFile(.{
            .file = b.path("src/gui/icons/kocr.rc"),
            .include_paths = &.{b.path("src/gui/icons")},
        });
    }

    const gui_input: bundler.Input = .{
        .executable = gui,
        .icons = .{
            .png = &.{b.path("src/gui/icons/linux")},
            .ico = b.path("src/gui/icons/kocr.ico"),
            .icns = b.path("src/gui/icons/kocr.icns"),
        },
    };

    const install_gui = b.addInstallArtifact(gui, .{});
    b.getInstallStep().dependOn(&install_gui.step);
    const gui_step = b.step("gui", "Build the native GUI");
    gui_step.dependOn(&install_gui.step);

    const gui_cmd = b.addRunArtifact(gui);
    gui_cmd.step.dependOn(&install_gui.step);
    gui_cmd.addPassthruArgs();
    const gui_run = b.step("run-gui", "Run the native GUI");
    gui_run.dependOn(&gui_cmd.step);

    const version = @import("build.zig.zon").version;

    const gui_app: bundler.App = .{
        .name = "kocr",
        .identifier = "io.github.KercyDing.kocr",
        .version = version,
        .publisher = "KercyDing <KercyDing@users.noreply.github.com>",
        .copyright = "Copyright 2026 KercyDing",
        .license = "MIT",
        .categories = "Utility;Graphics;",
        .description = "Offline OCR for images and screen captures",
    };
    const cli_app: bundler.App = .{
        .name = "kocr-cli",
        .identifier = "io.github.KercyDing.kocr.cli",
        .version = version,
        .publisher = gui_app.publisher,
        .copyright = gui_app.copyright,
        .license = gui_app.license,
        .description = "kocr command-line interface",
    };

    const cli_formats = selectFormat(.{ .zip = .{}, .tar_gz = .{} }, format);
    const cli_bundle_step = b.step("bundle-cli", "Package the CLI");
    if (hasFormats(cli_formats)) {
        const cli_bundle = bundler.add(b, .{
            .app = cli_app,
            .input = .{
                .executable = exe,
                .resources = &.{
                    .{ .source = b.path("README.md") },
                    .{ .source = b.path("LICENSE") },
                },
            },
            .formats = cli_formats,
        });
        cli_bundle_step.dependOn(cli_bundle.step);
    }

    const gui_bundle_step = b.step("bundle-gui", "Package the GUI");
    const os = target.result.os.tag;
    const all_gui_formats: bundler.Formats = switch (os) {
        .linux => .{
            .deb = .{
                .homepage = "https://github.com/KercyDing/kocr",
                .section = "graphics",
            },
            .rpm = .{
                .url = "https://github.com/KercyDing/kocr",
                .group = "Applications/Graphics",
            },
        },
        .windows => .{ .nsis = .{
            .install_scope = .current_user,
            .shortcuts = .{ .start_menu = true, .desktop = true },
            .launch_app = true,
        } },
        .macos => blk: {
            // A stable identity keeps the TCC Screen Recording grant across
            // updates; ad-hoc signatures change with every build.
            const sign: bundler.SignOptions = .{ .identity = codesign_identity };
            break :blk .{
                .app = .{
                    .plist_entries = &.{
                        bundler.plistBool("LSUIElement", true),
                        bundler.plistString("LSMinimumSystemVersion", "13.0"),
                        bundler.plistString("NSPrincipalClass", "NSApplication"),
                        bundler.plistString("NSScreenCaptureUsageDescription", "kocr captures a screen region to recognize text."),
                    },
                    .sign = sign,
                },
                .dmg = .{ .sign = sign },
            };
        },
        else => .{},
    };
    const gui_formats = selectFormat(all_gui_formats, format);
    if (hasFormats(gui_formats)) {
        const gui_bundle = bundler.add(b, .{
            .app = gui_app,
            .input = gui_input,
            .formats = gui_formats,
        });
        gui_bundle_step.dependOn(gui_bundle.step);
    }

    if (!hasFormats(cli_formats) and !hasFormats(gui_formats)) {
        std.process.fatal("bundle format '{s}' is not available on {s}", .{
            @tagName(format.?),
            @tagName(os),
        });
    }

    const bundle_step = b.step("bundle", "Package release artifacts");
    bundle_step.dependOn(cli_bundle_step);
    bundle_step.dependOn(gui_bundle_step);
}

fn selectFormat(all: bundler.Formats, format: ?bundler.Format) bundler.Formats {
    const selected = format orelse return all;
    return switch (selected) {
        .zip => .{ .zip = all.zip },
        .tar_gz => .{ .tar_gz = all.tar_gz },
        .deb => .{ .deb = all.deb },
        .rpm => .{ .rpm = all.rpm },
        .appimage => .{ .appimage = all.appimage },
        .nsis => .{ .nsis = all.nsis },
        .app => .{ .app = all.app },
        .dmg => .{ .dmg = all.dmg },
    };
}

fn hasFormats(formats: bundler.Formats) bool {
    return formats.zip != null or
        formats.tar_gz != null or
        formats.deb != null or
        formats.rpm != null or
        formats.appimage != null or
        formats.nsis != null or
        formats.app != null or
        formats.dmg != null;
}

fn linkWindowsLibraries(artifact: *std.Build.Step.Compile) void {
    for ([_][]const u8{ "user32", "gdi32", "comctl32", "comdlg32", "advapi32", "dwmapi" }) |lib| {
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
