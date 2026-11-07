const std = @import("std");
const proc = @import("../proc.zig");

pub const ClipboardError = error{
    ClipboardUnavailable,
    ClipboardWriteFailed,
};

pub fn copyText(
    _: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    text: []const u8,
) !void {
    return copy(io, environ, text, "text/plain;charset=utf-8");
}

pub fn copyImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
) !void {
    const image = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 << 20));
    defer allocator.free(image);
    return copy(io, environ, image, "image/png");
}

fn copy(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    content: []const u8,
    mime: []const u8,
) !void {
    const wayland = if (environ.get("WAYLAND_DISPLAY")) |value| value.len != 0 else false;
    if (wayland) {
        if (try copyWith(io, environ, &.{ "wl-copy", "--type", mime }, content)) return;
    }
    if (try copyWith(io, environ, &.{ "xclip", "-selection", "clipboard", "-t", mime }, content)) return;
    if (try copyWith(io, environ, &.{ "xsel", "--clipboard", "--input" }, content)) return;
    return ClipboardError.ClipboardUnavailable;
}

fn copyWith(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    argv: []const []const u8,
    content: []const u8,
) !bool {
    var child = proc.spawn(io, environ, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const stdin = child.stdin orelse return false;
    stdin.writeStreamingAll(io, content) catch {
        child.stdin = null;
        stdin.close(io);
        child.kill(io);
        return false;
    };
    child.stdin = null;
    stdin.close(io);
    return true;
}
