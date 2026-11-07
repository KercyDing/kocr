//! macOS region capture through the system screencapture tool.

const std = @import("std");
const proc = @import("../proc.zig");

pub const Capture = enum {
    saved,
    cancelled,
};

pub const CaptureError = error{
    ScreencaptureNotFound,
    CaptureFailed,
    InvalidOutputPath,
};

pub const dependencies = [_][]const u8{"screencapture"};

const executable = "/usr/sbin/screencapture";

pub fn captureRegion(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    output_path: []const u8,
) !Capture {
    if (output_path.len == 0) return error.InvalidOutputPath;

    // screencapture leaves a stale file behind when the selection is cancelled.
    std.Io.Dir.cwd().deleteFile(io, output_path) catch {};

    const result = proc.run(allocator, io, environ, .{
        .argv = &.{ executable, "-i", "-x", output_path },
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.ScreencaptureNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    var file = std.Io.Dir.cwd().openFile(io, output_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .cancelled,
        else => return err,
    };
    file.close(io);
    if (!result.term.success()) return error.CaptureFailed;
    return .saved;
}
