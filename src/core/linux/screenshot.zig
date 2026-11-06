//! KDE Spectacle region capture. Mirrors kocr-rs's Linux backend.

const std = @import("std");

pub const Capture = enum {
    saved,
    cancelled,
};

pub const CaptureError = error{
    SpectacleNotFound,
    CaptureFailed,
    InvalidOutputPath,
};

pub const dependencies = [_][]const u8{ "spectacle", "notify-send" };

pub fn captureRegion(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_path: []const u8,
) !Capture {
    if (output_path.len == 0) return error.InvalidOutputPath;

    const release_capture = try supportsReleaseCapture(allocator, io);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "spectacle", "--region", "--background", "--nonotify" });
    if (release_capture) try argv.append(allocator, "--release-capture");
    try argv.appendSlice(allocator, &.{ "--output", output_path });

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SpectacleNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const output_exists = blk: {
        var file = std.Io.Dir.cwd().openFile(io, output_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        file.close(io);
        break :blk true;
    };

    if (!output_exists) {
        if (result.term.success()) return .cancelled;
        return error.CaptureFailed;
    }
    if (!result.term.success()) return error.CaptureFailed;
    return .saved;
}

fn supportsReleaseCapture(allocator: std.mem.Allocator, io: std.Io) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "spectacle", "--help" },
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SpectacleNotFound,
        else => return err,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return std.mem.indexOf(u8, result.stdout, "--release-capture") != null or
        std.mem.indexOf(u8, result.stderr, "--release-capture") != null;
}
