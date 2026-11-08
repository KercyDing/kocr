//! Platform model storage, matching kocr's previous data layout:
//! `<local data>/kocr/models/<profile>`.

const std = @import("std");
const builtin = @import("builtin");

const known_folders = @import("known_folders");

fn dataFolder() known_folders.KnownFolder {
    return switch (builtin.os.tag) {
        .windows => .local_configuration,
        else => .data,
    };
}

pub fn dataRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    // KOCR_DATA_HOME overrides the platform folder; Windows ignores the env map.
    if (environ.get("KOCR_DATA_HOME")) |root| {
        if (root.len != 0) return allocator.dupe(u8, root);
    }
    const base = try known_folders.getPath(io, allocator, environ, dataFolder()) orelse
        return error.DataDirUnavailable;
    defer allocator.free(base);
    return std.Io.Dir.path.join(allocator, &.{ base, "kocr" });
}

pub fn modelsRoot(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const root = try dataRoot(io, allocator, environ);
    defer allocator.free(root);
    return std.Io.Dir.path.join(allocator, &.{ root, "models" });
}

pub fn profileDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    profile: []const u8,
) ![]u8 {
    const root = try modelsRoot(io, allocator, environ);
    defer allocator.free(root);
    const name = try std.fmt.allocPrint(allocator, "ppocrv6-{s}", .{profile});
    defer allocator.free(name);
    return std.Io.Dir.path.join(allocator, &.{ root, name });
}
