//! Persistent GUI/CLI configuration in `<config>/kocr/config.json`.

const std = @import("std");

const known_folders = @import("known_folders");

pub const Config = struct {
    models: Models = .{},
    shortcuts: Shortcuts = .{},

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

pub fn path(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const base = try known_folders.getPath(io, allocator, environ, .roaming_configuration) orelse
        return error.ConfigDirUnavailable;
    defer allocator.free(base);
    return std.Io.Dir.path.join(allocator, &.{ base, "kocr", "config.json" });
}

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !std.json.Parsed(Config) {
    const file = try path(io, allocator, environ);
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
    const file = try path(io, allocator, environ);
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
