//! macOS clipboard through the system pbcopy and osascript tools.

const std = @import("std");

pub const ClipboardError = error{
    ClipboardUnavailable,
    ClipboardWriteFailed,
};

const pbcopy = "/usr/bin/pbcopy";
const osascript = "/usr/bin/osascript";

pub fn copyText(
    _: std.mem.Allocator,
    io: std.Io,
    _: *const std.process.Environ.Map,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    var child = std.process.spawn(io, .{
        .argv = &.{pbcopy},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return ClipboardError.ClipboardUnavailable;
    const stdin = child.stdin orelse {
        child.kill(io);
        return ClipboardError.ClipboardUnavailable;
    };
    child.stdin = null;
    stdin.writeStreamingAll(io, text) catch {
        stdin.close(io);
        child.kill(io);
        return ClipboardError.ClipboardWriteFailed;
    };
    stdin.close(io);
    const term = child.wait(io) catch return ClipboardError.ClipboardWriteFailed;
    if (!term.success()) return ClipboardError.ClipboardWriteFailed;
}

pub fn copyImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: *const std.process.Environ.Map,
    path: []const u8,
) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch
        return ClipboardError.ClipboardWriteFailed;
    file.close(io);

    const escaped = try escape(allocator, path);
    defer allocator.free(escaped);
    const script = try std.fmt.allocPrint(
        allocator,
        "set the clipboard to (read (POSIX file \"{s}\") as «class PNGf»)",
        .{escaped},
    );
    defer allocator.free(script);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ osascript, "-e", script },
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
    }) catch return ClipboardError.ClipboardUnavailable;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return ClipboardError.ClipboardWriteFailed;
}

/// Escapes a path for a double-quoted AppleScript string.
fn escape(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (path) |byte| switch (byte) {
        '\\' => try text.appendSlice(allocator, "\\\\"),
        '"' => try text.appendSlice(allocator, "\\\""),
        else => try text.append(allocator, byte),
    };
    return text.toOwnedSlice(allocator);
}

test "escapes AppleScript paths" {
    const allocator = std.testing.allocator;
    const escaped = try escape(allocator, "/tmp/a\\b\"c.png");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("/tmp/a\\\\b\\\"c.png", escaped);
}
