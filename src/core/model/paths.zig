//! Platform model storage, matching kocr's previous data layout:
//! `<local data>/Kocr/models/<profile>`.

const std = @import("std");

const dirs = @import("../dirs.zig");

pub fn dataRoot(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    // KOCR_DATA_HOME overrides the platform folder.
    if (environ.get("KOCR_DATA_HOME")) |root| {
        if (root.len != 0) return allocator.dupe(u8, root);
    }
    const base = try dirs.dataRoot(allocator, environ);
    defer allocator.free(base);
    return std.Io.Dir.path.join(allocator, &.{ base, dirs.name });
}

pub fn modelsRoot(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const root = try dataRoot(allocator, environ);
    defer allocator.free(root);
    return std.Io.Dir.path.join(allocator, &.{ root, "models" });
}

pub fn profileDir(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    profile: []const u8,
) ![]u8 {
    const root = try modelsRoot(allocator, environ);
    defer allocator.free(root);
    const name = try std.fmt.allocPrint(allocator, "ppocrv6-{s}", .{profile});
    defer allocator.free(name);
    return std.Io.Dir.path.join(allocator, &.{ root, name });
}
