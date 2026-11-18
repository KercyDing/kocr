const std = @import("std");
const builtin = @import("builtin");
const core = @import("core");
const downloader = core.downloader;
const minisign = core.minisign;

pub const current_version = @import("build_options").version;

const cnb = "https://cnb.cool/KercyDing/kocr/-";
const github = "https://github.com/KercyDing/kocr";
const windows = builtin.os.tag == .windows;
const executable_name = if (windows) "kocr.exe" else "kocr";

extern "kernel32" fn MoveFileExW(
    existing: [*:0]const u16,
    destination: [*:0]const u16,
    flags: u32,
) callconv(.winapi) i32;

pub fn run(init: std.process.Init, progress: downloader.Progress) !?[]const u8 {
    const os = switch (builtin.os.tag) {
        .windows => "windows",
        .linux => "linux",
        .macos => "macos",
        else => return error.UnsupportedUpdatePlatform,
    };
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedUpdatePlatform,
    };
    const io = init.io;
    const allocator = init.arena.allocator();
    const public_key = try minisign.PublicKey.parse(@import("update_options").public_key);
    const current = try std.SemanticVersion.parse(current_version);

    const release = latest(init, cnb ++ "/badge/release.link") catch
        try latest(init, github ++ "/releases/latest");
    if (release.order(current) != .gt) return null;

    const exe = try std.process.executablePathAlloc(io, allocator);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.update.lock", .{exe});
    const cwd = std.Io.Dir.cwd();
    const lock = try cwd.createFile(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    });
    defer lock.close(io);

    // Stage beside the executable so the final rename stays on one filesystem.
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const staging = try std.fmt.allocPrint(allocator, "{s}.update-{s}", .{
        exe, std.fmt.bytesToHex(nonce, .lower),
    });
    try cwd.createDir(io, staging, .default_dir);
    defer cwd.deleteTree(io, staging) catch {};
    const archive = try std.fs.path.join(allocator, &.{ staging, "archive" });
    const signature = try std.fs.path.join(allocator, &.{ staging, "signature.minisig" });
    const unpacked = try std.fs.path.join(allocator, &.{ staging, "unpacked" });
    try cwd.createDir(io, unpacked, .default_dir);

    const version = try std.fmt.allocPrint(allocator, "{f}", .{release});
    const extension = if (windows) "zip" else "tar.gz";
    const name = try std.fmt.allocPrint(allocator, "kocr-cli-{s}-{s}-{s}.{s}", .{
        version, arch, os, extension,
    });
    const relative = try std.fmt.allocPrint(allocator, "/releases/download/v{s}/{s}", .{ version, name });
    const cnb_url = try std.mem.concat(allocator, u8, &.{ cnb, relative });
    downloadRelease(init, public_key, cnb_url, name, archive, signature, progress) catch |err| {
        std.log.warn("CNB download failed ({s}), trying GitHub", .{@errorName(err)});
        const github_url = try std.mem.concat(allocator, u8, &.{ github, relative });
        try downloadRelease(init, public_key, github_url, name, archive, signature, progress);
    };

    if (windows) {
        try downloader.extract(io, archive, unpacked);
    } else {
        try extractTar(io, archive, unpacked);
    }
    const replacement = try std.fs.path.join(allocator, &.{ unpacked, executable_name });
    const replacement_stat = try cwd.statFile(io, replacement, .{ .follow_symlinks = false });
    if (replacement_stat.kind != .file or replacement_stat.size == 0) return error.InvalidReleaseExecutable;
    if (windows) {
        try replaceWindows(init, exe, replacement);
    } else {
        try std.Io.Dir.renameAbsolute(replacement, exe, io);
    }
    return version;
}

fn latest(init: std.process.Init, url: []const u8) !std.SemanticVersion {
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = .unhandled,
    });
    defer request.deinit();
    try request.sendBodiless();
    var buffer: [4096]u8 = undefined;
    const response = try request.receiveHead(&buffer);
    if (response.head.status.class() != .redirect) return error.ReleaseLookupFailed;
    const location = response.head.location orelse return error.ReleaseLookupFailed;
    const path = location[0 .. std.mem.indexOfAny(u8, location, "?#") orelse location.len];
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const tag = trimmed[if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| i + 1 else 0..];
    if (!std.mem.startsWith(u8, tag, "v")) return error.InvalidReleaseTag;
    const version = try std.SemanticVersion.parse(tag[1..]);
    if (version.pre != null or version.build != null) return error.InvalidReleaseTag;
    return version;
}

fn downloadRelease(
    init: std.process.Init,
    public_key: minisign.PublicKey,
    url: []const u8,
    asset_name: []const u8,
    archive: []const u8,
    signature: []const u8,
    progress: downloader.Progress,
) !void {
    const allocator = init.gpa;
    const io = init.io;
    const signature_url = try std.mem.concat(allocator, u8, &.{ url, ".minisig" });
    defer allocator.free(signature_url);
    try downloader.download(io, allocator, signature_url, signature, null);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, signature, allocator, .limited(4096));
    defer allocator.free(contents);
    try downloader.download(io, allocator, url, archive, progress);
    try public_key.verify(io, archive, contents, asset_name);
}

fn extractTar(io: std.Io, archive: []const u8, destination: []const u8) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, archive, .{});
    defer file.close(io);
    const dir = try std.Io.Dir.openDirAbsolute(io, destination, .{});
    defer dir.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &file_buffer);
    var inflate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate = std.compress.flate.Decompress.init(&reader.interface, .gzip, &inflate_buffer);
    try std.tar.extract(io, dir, &inflate.reader, .{});
}

fn replaceWindows(init: std.process.Init, exe: []const u8, replacement: []const u8) !void {
    const allocator = init.arena.allocator();
    const backup = try std.fmt.allocPrint(allocator, "{s}.update.old", .{exe});
    const exe_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, exe);
    const backup_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, backup);
    std.Io.Dir.cwd().deleteFile(init.io, backup) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (MoveFileExW(exe_w, backup_w, 0) == 0) return error.CannotMoveRunningExecutable;
    std.Io.Dir.renameAbsolute(replacement, exe, init.io) catch |err| {
        if (MoveFileExW(backup_w, exe_w, 0) == 0) {
            std.log.err("Previous executable is available at {s}", .{backup});
            return error.UpdateRollbackFailed;
        }
        return err;
    };
    // Windows holds the old image open until this process exits. The next
    // successful update can discard that backup before moving its own image.
}
