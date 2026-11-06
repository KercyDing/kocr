pub const paths = @import("paths.zig");
pub const rec = @import("rec.zig");
pub const det = @import("det.zig");
pub const cls = @import("cls.zig");

const std = @import("std");

pub const Manifest = struct {
    profile: []const u8,
    keys: []const u8,
    blank_index: usize = 0,
    space_index: usize,
    det: Tensor,
    rec: Tensor,
    cls: ?Tensor = null,

    pub const Tensor = struct {
        param: []const u8,
        bin: []const u8,
        input: []const u8,
        output: []const u8,
    };
};

pub fn loadManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
) !?std.json.Parsed(Manifest) {
    const path = try std.Io.Dir.path.join(allocator, &.{ dir, "manifest.json" });
    defer allocator.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(content);

    return try std.json.parseFromSlice(Manifest, allocator, content, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}
