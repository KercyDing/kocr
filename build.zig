const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
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
