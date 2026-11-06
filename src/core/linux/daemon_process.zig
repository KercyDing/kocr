const std = @import("std");

const config = @import("config");

pub const DaemonError = error{
    AlreadyRunning,
    DaemonNotFound,
    ProcessControlUnavailable,
};

pub fn isRunning(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !bool {
    const path = try pidPath(io, allocator, environ);
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64)) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer allocator.free(content);
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, content, " \t\r\n"), 10) catch return false;
    if (pid <= 0) return false;
    var proc_path_buf: [32]u8 = undefined;
    const proc_path = std.fmt.bufPrint(&proc_path_buf, "/proc/{d}", .{pid}) catch return false;
    var proc_dir = std.Io.Dir.cwd().openDir(io, proc_path, .{}) catch return false;
    proc_dir.close(io);
    return true;
}

/// Claims the daemon pid file and writes the current pid.
pub fn acquire(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    if (try isRunning(io, allocator, environ)) return error.AlreadyRunning;
    const path = try pidPath(io, allocator, environ);
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    const content = try std.fmt.allocPrint(allocator, "{d}\n", .{std.os.linux.getpid()});
    defer allocator.free(content);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = content });
}

pub fn release(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) void {
    const path = pidPath(io, allocator, environ) catch return;
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub fn stop(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    const path = try pidPath(io, allocator, environ);
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(content);
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, content, " \t\r\n"), 10) catch {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return;
    };
    std.posix.kill(pid, .TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Starts the sibling `kocr daemon` if the pid file is not live.
pub fn ensureRunning(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !bool {
    if (try isRunning(io, allocator, environ)) return false;
    const dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(dir);
    const executable = try std.Io.Dir.path.join(allocator, &.{ dir, "kocr" });
    defer allocator.free(executable);
    const config_dir = try config.dir(io, allocator, environ);
    defer allocator.free(config_dir);
    const log_path = try std.Io.Dir.path.join(allocator, &.{ config_dir, "daemon.log" });
    defer allocator.free(log_path);
    const log_file: ?std.Io.File = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch null;
    defer if (log_file) |file| file.close(io);
    const output: std.process.SpawnOptions.StdIo = if (log_file) |file| .{ .file = file } else .ignore;
    var child = std.process.spawn(io, .{
        .argv = &.{ "setsid", "-f", executable, "daemon" },
        .stdin = .ignore,
        .stdout = output,
        .stderr = output,
    }) catch return error.ProcessControlUnavailable;
    _ = &child;
    std.Io.sleep(io, .{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
    return isRunning(io, allocator, environ);
}

fn pidPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const dir = try config.dir(io, allocator, environ);
    defer allocator.free(dir);
    return std.Io.Dir.path.join(allocator, &.{ dir, "daemon.pid" });
}
