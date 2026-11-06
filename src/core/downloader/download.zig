//! Model package download and installation using only the Zig standard library.

const std = @import("std");

pub const catalog = @import("catalog.zig");

const model = @import("../model/model.zig").paths;

pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, downloaded: u64, total: u64) void,
};

pub const InstallOptions = struct {
    force: bool = false,
    progress: ?Progress = null,
};

pub const InstallError = error{
    UnknownProfile,
    AlreadyInstalled,
    NotInstalled,
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

    if (!try downloadVerified(io, allocator, package.cnb_url, archive, package.sha256, options.progress)) {
        if (!try downloadVerified(io, allocator, package.github_url, archive, package.sha256, options.progress))
            return InstallError.DownloadFailed;
    }

    try std.Io.Dir.cwd().createDirPath(io, staging);
    try extract(io, archive, staging);
    try std.Io.Dir.renameAbsolute(staging, target, io);
    return target;
}

pub fn isInstalled(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    profile: []const u8,
) !bool {
    const target = try model.profileDir(io, allocator, environ, profile);
    defer allocator.free(target);
    var dir = std.Io.Dir.cwd().openDir(io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    dir.close(io);
    return true;
}

pub fn remove(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    profile: []const u8,
) !void {
    const target = try model.profileDir(io, allocator, environ, profile);
    defer allocator.free(target);
    try std.Io.Dir.cwd().deleteTree(io, target);
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
    progress: ?Progress,
) !bool {
    download(io, allocator, url, destination, progress) catch return false;
    return verify(io, destination, expected) catch false;
}

fn download(
    io: std.Io,
    allocator: std.mem.Allocator,
    url: []const u8,
    destination: []const u8,
    progress: ?Progress,
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(url) catch return InstallError.DownloadFailed;
    var request = client.request(.GET, uri, .{}) catch return InstallError.DownloadFailed;
    defer request.deinit();
    request.sendBodiless() catch return InstallError.DownloadFailed;

    var header_buffer: [16 * 1024]u8 = undefined;
    var response = request.receiveHead(&header_buffer) catch return InstallError.DownloadFailed;
    if (response.head.status != .ok) return InstallError.DownloadFailed;

    const total = response.head.content_length orelse 0;
    if (progress) |callback| callback.report(callback.context, 0, total);

    var file = try std.Io.Dir.cwd().createFile(io, destination, .{ .truncate = true });
    defer file.close(io);

    var transfer_buffer: [64 * 1024]u8 = undefined;
    var reader = response.reader(&transfer_buffer);
    var chunk: [64 * 1024]u8 = undefined;
    var downloaded: u64 = 0;
    while (true) {
        const len = reader.readSliceShort(&chunk) catch return InstallError.DownloadFailed;
        if (len == 0) break;
        try file.writeStreamingAll(io, chunk[0..len]);
        downloaded += @intCast(len);
        if (progress) |callback| callback.report(callback.context, downloaded, total);
    }
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
