//! Model package download and installation using only the Zig standard library.

const std = @import("std");

pub const catalog = @import("catalog.zig");

pub const InstallOptions = struct {
    force: bool = false,
};

pub const InstallError = error{
    UnknownProfile,
    AlreadyInstalled,
    DownloadFailed,
    HashMismatch,
    InvalidArchive,
};

/// Downloads, verifies and atomically installs a model package.
/// Returns the final model directory, owned by `allocator`.
pub fn install(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    profile: []const u8,
    options: InstallOptions,
) ![]u8 {
    const package = catalog.find(profile) orelse return InstallError.UnknownProfile;
    const root = try model.modelsRoot(io, allocator, environ);
    defer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    const target = try model.profileDir(io, allocator, environ, profile);
    errdefer allocator.free(target);

    if (std.Io.Dir.cwd().openDir(io, target, .{})) |dir| {
        var opened = dir;
        opened.close(io);
        if (!options.force) return InstallError.AlreadyInstalled;
        try std.Io.Dir.cwd().deleteTree(io, target);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const archive = try std.fmt.allocPrint(allocator, "{s}.zip.tmp", .{target});
    defer allocator.free(archive);
    const staging = try std.fmt.allocPrint(allocator, "{s}.tmp", .{target});
    defer allocator.free(staging);

    cleanup(io, archive);
    cleanup(io, staging);
    defer cleanup(io, archive);
    defer cleanup(io, staging);

    if (!try downloadVerified(io, allocator, package.cnb_url, archive, package.sha256)) {
        if (!try downloadVerified(io, allocator, package.github_url, archive, package.sha256))
            return InstallError.DownloadFailed;
    }

    try std.Io.Dir.cwd().createDirPath(io, staging);
    try extract(io, archive, staging);
    try std.Io.Dir.renameAbsolute(staging, target, io);
    return target;
}

fn cleanup(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn downloadVerified(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    destination: []const u8,
    expected: []const u8,
) !bool {
    download(io, allocator, url, destination) catch return false;
    return verify(io, destination, expected) catch false;
}

fn download(io: std.Io, allocator: std.mem.Allocator, url: []const u8, destination: []const u8) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var file = try std.Io.Dir.cwd().createFile(io, destination, .{ .truncate = true });
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &file_buffer);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &writer.interface,
    }) catch return InstallError.DownloadFailed;
    try writer.end();
    if (result.status != .ok) return InstallError.DownloadFailed;
}

fn verify(io: std.Io, path: []const u8, expected: []const u8) !bool {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const len = try reader.interface.readSliceShort(&chunk);
        if (len == 0) break;
        hasher.update(chunk[0..len]);
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, &hex, expected);
}

fn extract(io: std.Io, archive: []const u8, destination: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);

    var dir = try std.Io.Dir.cwd().openDir(io, destination, .{});
    defer dir.close(io);
    std.zip.extract(dir, &reader, .{}) catch return InstallError.InvalidArchive;
}

const model = @import("../model/paths.zig");
