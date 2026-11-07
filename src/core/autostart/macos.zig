//! macOS login autostart through a LaunchAgent.

const std = @import("std");

const known_folders = @import("known_folders");

const file_name = "io.github.KercyDing.kocr.daemon.plist";
const label = "io.github.KercyDing.kocr.daemon";

pub fn enabled(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !bool {
    const path = try plistPath(io, allocator, environ);
    defer allocator.free(path);
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

pub fn set(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    install: bool,
    daemon_executable: []const u8,
) !void {
    const path = try plistPath(io, allocator, environ);
    defer allocator.free(path);
    if (!install) {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    if (daemon_executable.len == 0 or
        !std.Io.Dir.path.isAbsolute(daemon_executable)) return error.InvalidExecutable;

    const escaped = try escape(allocator, daemon_executable);
    defer allocator.free(escaped);
    const content = try std.fmt.allocPrint(
        allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>{s}</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\        <string>--daemon</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    ,
        .{ label, escaped },
    );
    defer allocator.free(content);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

fn plistPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const home = try known_folders.getPath(io, allocator, environ, .home) orelse
        return error.HomeDirUnavailable;
    defer allocator.free(home);
    return std.Io.Dir.path.join(allocator, &.{ home, "Library", "LaunchAgents", file_name });
}

/// Escapes a path for a plist string.
fn escape(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var escaped: std.ArrayList(u8) = .empty;
    errdefer escaped.deinit(allocator);
    for (text) |byte| switch (byte) {
        '&' => try escaped.appendSlice(allocator, "&amp;"),
        '<' => try escaped.appendSlice(allocator, "&lt;"),
        '>' => try escaped.appendSlice(allocator, "&gt;"),
        else => try escaped.append(allocator, byte),
    };
    return escaped.toOwnedSlice(allocator);
}

test "escapes plist paths" {
    const allocator = std.testing.allocator;
    const escaped = try escape(allocator, "/tmp/a&b<c>.app");
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("/tmp/a&amp;b&lt;c&gt;.app", escaped);
}
