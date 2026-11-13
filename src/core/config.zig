//! Persistent GUI/CLI configuration in `<config>/Kocr/config.json`.

const std = @import("std");

const dirs = @import("dirs.zig");

/// The window colors; `auto` follows the system.
pub const Theme = enum { auto, light, dark };

pub const Config = struct {
    models: Models = .{},
    shortcuts: Shortcuts = .{},
    ui: Ui = .{},

    pub const Ui = struct {
        tray: bool = true,
        theme: Theme = .auto,
    };

    pub const Models = struct {
        select: ?[]const u8 = null,
    };

    pub const Shortcuts = struct {
        copy: ?[]const u8 = null,
        save: ?[]const u8 = null,
        ocr: ?[]const u8 = null,
        oneline: ?[]const u8 = null,
    };
};

pub fn dir(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const base = try dirs.configRoot(allocator, environ);
    defer allocator.free(base);
    return std.Io.Dir.path.join(allocator, &.{ base, dirs.name });
}

pub fn path(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const config_dir = try dir(allocator, environ);
    defer allocator.free(config_dir);
    return std.Io.Dir.path.join(allocator, &.{ config_dir, "config.json" });
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !std.json.Parsed(Config) {
    const file = try path(allocator, environ);
    defer allocator.free(file);
    const content = std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return std.json.parseFromSlice(Config, allocator, "{}", .{}),
        else => return err,
    };
    defer allocator.free(content);
    return std.json.parseFromSlice(Config, allocator, content, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    config: Config,
) !void {
    const file = try path(allocator, environ);
    defer allocator.free(file);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(file) orelse ".");
    const json = try std.json.Stringify.valueAlloc(allocator, config, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(json);
    const content = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    defer allocator.free(content);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = content });
}
