//! Windows daemon: shared loop plus pid-file process control.

const std = @import("std");

const core = @import("core");
const win32 = @import("win32");

const native = @import("native.zig");

const mutex_name = win32.zig.L("Local\\kocr-daemon");

pub fn initProcess() void {
    if (win32.user32.SetProcessDpiAwarenessContext(win32.ui.hi_dpi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0) {
        _ = win32.user32.SetProcessDPIAware();
    }
}

pub fn run(init: std.process.Init) !void {
    writeLog(init, "starting\n");
    runInner(init) catch |err| {
        var buffer: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "failed: {s}\n", .{@errorName(err)}) catch "failed\n";
        writeLog(init, text);
        return err;
    };
}

fn writeLog(init: std.process.Init, text: []const u8) void {
    const dir = core.config.dir(init.io, init.gpa, init.environ_map) catch return;
    defer init.gpa.free(dir);
    const path = std.Io.Dir.path.join(init.gpa, &.{ dir, "daemon.log" }) catch return;
    defer init.gpa.free(path);
    std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = text }) catch {};
}

fn runInner(init: std.process.Init) !void {
    kernel32.SetLastError(foundation.ERROR_SUCCESS);
    const mutex = kernel32.CreateMutexW(null, 0, mutex_name) orelse return DaemonError.ProcessControlUnavailable;
    defer _ = kernel32.CloseHandle(mutex);
    if (kernel32.GetLastError() == foundation.ERROR_ALREADY_EXISTS) return DaemonError.AlreadyRunning;
    writeLog(init, "mutex\n");
    acquire(init.io, init.gpa, init.environ_map) catch |err| switch (err) {
        error.AlreadyRunning => return,
        else => return err,
    };
    writeLog(init, "acquired\n");
    defer release(init.io, init.gpa, init.environ_map);
    try native.serve(init);
}

const kernel32 = win32.kernel32;
const threading = win32.system.threading;
const foundation = win32.foundation;

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
    if (kernel32.OpenMutexW(.{ .SYNCHRONIZATION_SYNCHRONIZE = 1 }, 0, mutex_name)) |mutex| {
        _ = kernel32.CloseHandle(mutex);
        return true;
    }
    return pidRunning(io, allocator, environ);
}

/// Process liveness from the pid file alone: the daemon's own mutex says it
/// is alive, so `acquire` must not consult it.
fn pidRunning(
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
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, content, " \t\r\n"), 10) catch return false;
    if (pid == 0) return false;
    const process = kernel32.OpenProcess(threading.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return false;
    defer _ = kernel32.CloseHandle(process);
    return kernel32.WaitForSingleObject(process, 0) == foundation.WAIT_TIMEOUT;
}

/// Claims the daemon pid file and writes the current pid.
pub fn acquire(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    if (try pidRunning(io, allocator, environ)) return DaemonError.AlreadyRunning;
    const path = try pidPath(io, allocator, environ);
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    const content = try std.fmt.allocPrint(allocator, "{d}\n", .{kernel32.GetCurrentProcessId()});
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
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64)) catch return;
    defer allocator.free(content);
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, content, " \t\r\n"), 10) catch return;
    if (pid != kernel32.GetCurrentProcessId()) return;
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
    const pid = std.fmt.parseInt(u32, std.mem.trim(u8, content, " \t\r\n"), 10) catch {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        return;
    };
    if (pid != 0) {
        if (kernel32.OpenProcess(threading.PROCESS_TERMINATE, 0, pid)) |process| {
            defer _ = kernel32.CloseHandle(process);
            _ = kernel32.TerminateProcess(process, 0);
        }
    }
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// Starts the current executable in daemon mode if the pid file is not live.
pub fn ensureRunning(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    if (try isRunning(io, allocator, environ)) return DaemonError.AlreadyRunning;
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    var child = std.process.spawn(io, .{
        .argv = &.{ executable, "--daemon" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return DaemonError.ProcessControlUnavailable;
    child.stdin = null;
    var waited: u32 = 0;
    while (waited < 3000) : (waited += 100) {
        if (try isRunning(io, allocator, environ)) return;
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch {};
    }
    return DaemonError.ProcessControlUnavailable;
}

fn pidPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const dir = try core.config.dir(io, allocator, environ);
    defer allocator.free(dir);
    return std.Io.Dir.path.join(allocator, &.{ dir, "daemon.pid" });
}
