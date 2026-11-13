const std = @import("std");

const config = @import("../config.zig");

const file_name = "kocr-daemon.desktop";

pub fn enabled(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !bool {
    const path = try desktopPath(allocator, environ);
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
    const path = try desktopPath(allocator, environ);
    defer allocator.free(path);
    if (!install) {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    const content = try std.fmt.allocPrint(
        allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=kocr daemon
        \\Comment=Global shortcuts and OCR daemon
        \\Icon=kocr
        \\Exec="{s}" --daemon
        \\Terminal=false
        \\X-GNOME-Autostart-enabled=true
        \\
    ,
        .{daemon_executable},
    );
    defer allocator.free(content);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

fn desktopPath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const dir = try config.dir(allocator, environ);
    defer allocator.free(dir);
    const config_root = std.Io.Dir.path.dirname(dir) orelse return error.ConfigDirUnavailable;
    return std.Io.Dir.path.join(allocator, &.{ config_root, "autostart", file_name });
}
