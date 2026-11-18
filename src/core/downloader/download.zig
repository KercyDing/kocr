//! Model package download and installation.

const std = @import("std");

const downloader = @import("downloader");

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
    init: std.process.Init,
    profile: []const u8,
    options: InstallOptions,
) ![]u8 {
    const io = init.io;
    const allocator = init.gpa;
    const environ = init.environ_map;

    const package = catalog.find(profile) orelse return InstallError.UnknownProfile;
    const root = try model.modelsRoot(allocator, environ);
    defer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    const target = try model.profileDir(allocator, environ, profile);
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

    if (!try downloadVerified(init, package.cnb_url, archive, package.sha256, options.progress)) {
        if (!try downloadVerified(init, package.github_url, archive, package.sha256, options.progress))
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
    const target = try model.profileDir(allocator, environ, profile);
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
    const target = try model.profileDir(allocator, environ, profile);
    defer allocator.free(target);
    try std.Io.Dir.cwd().deleteTree(io, target);
}

fn cleanup(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn downloadVerified(
    init: std.process.Init,
    url: []const u8,
    destination: []const u8,
    expected: []const u8,
    progress: ?Progress,
) !bool {
    download(init, url, destination, progress) catch return false;
    return verify(init.io, destination, expected) catch false;
}

pub fn download(
    init: std.process.Init,
    url: []const u8,
    destination: []const u8,
    progress: ?Progress,
) !void {
    var bridge: ?downloader.Progress = null;
    if (progress) |callback| {
        bridge = .{ .context = callback.context, .report = callback.report };
    }

    downloader.download(init, url, destination, .{
        .retries = 2,
        .retry_delay_ms = 500,
        .progress = bridge,
    }) catch return InstallError.DownloadFailed;
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

pub fn extract(io: std.Io, archive: []const u8, destination: []const u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, archive, .{});
    defer file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);

    var dir = try std.Io.Dir.cwd().openDir(io, destination, .{});
    defer dir.close(io);
    std.zip.extract(dir, &reader, .{}) catch return InstallError.InvalidArchive;
}
