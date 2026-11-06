//! Shortcut daemon: captures and OCR runs independently of the GUI.

const std = @import("std");

const core = @import("core");

const config = core.config;

pub fn run(init: std.process.Init) !void {
    const ignore_pipe = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &ignore_pipe, null);

    const lock_file = lock(init.io, init.gpa, init.environ_map) catch |err| switch (err) {
        error.AlreadyRunning => return,
        else => return err,
    };
    defer lock_file.close(init.io);
    acquire(init.io, init.gpa, init.environ_map) catch |err| switch (err) {
        error.AlreadyRunning => return,
        else => return err,
    };
    defer release(init.io, init.gpa, init.environ_map);
    var daemon = Daemon{
        .allocator = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
    };
    daemon.worker = try std.Thread.spawn(.{}, workerLoop, .{&daemon});
    defer daemon.stopWorker();

    core.listenConfigured(init.gpa, init.io, init.environ_map, &daemon, handle) catch |err| {
        notify(&daemon, "kocr daemon failed", @errorName(err));
        return err;
    };
}

const action_capacity: u32 = 16;

const ActionQueue = struct {
    buffer: [action_capacity]u8 = undefined,
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn push(self: *ActionQueue, action: core.Action) bool {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (tail - head >= action_capacity) return false;
        self.buffer[tail % action_capacity] = @backingInt(action);
        self.tail.store(tail + 1, .release);
        return true;
    }

    fn pop(self: *ActionQueue) ?core.Action {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head == tail) return null;
        const action: core.Action = @fromBackingInt(@intCast(self.buffer[head % action_capacity]));
        self.head.store(head + 1, .release);
        return action;
    }
};

const Daemon = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    queue: ActionQueue = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    worker: ?std.Thread = null,

    fn stopWorker(self: *Daemon) void {
        self.running.store(false, .release);
        if (self.worker) |thread| thread.join();
        self.worker = null;
    }
};

fn handle(context: *anyopaque, action: core.Action) !bool {
    const daemon: *Daemon = @ptrCast(@alignCast(context));
    if (!daemon.queue.push(action)) {
        std.debug.print("kocr: action queue full, dropping {s}\n", .{@tagName(action)});
    }
    return true;
}

fn workerLoop(daemon: *Daemon) void {
    while (daemon.running.load(.acquire)) {
        if (daemon.queue.pop()) |action| {
            runAction(daemon, action) catch |err| {
                std.debug.print("kocr: action {s} failed: {s}\n", .{ @tagName(action), @errorName(err) });
                notify(daemon, "kocr action failed", @errorName(err));
            };
        } else {
            std.Io.sleep(daemon.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
        }
    }
}

fn runAction(daemon: *Daemon, action: core.Action) !void {
    const path = try tempPath(daemon);
    defer daemon.allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(daemon.io, path) catch {};

    if (try core.captureRegion(daemon.allocator, daemon.io, path) == .cancelled) return;

    switch (action) {
        .copy => {
            try core.clipboard.copyImage(daemon.allocator, daemon.io, daemon.environ, path);
            try core.history.appendImage(daemon.io, daemon.allocator, daemon.environ, path);
        },
        .save => {
            const destination = try chooseSavePath(daemon);
            defer daemon.allocator.free(destination);
            if (destination.len == 0) return;
            try std.Io.Dir.copyFileAbsolute(path, destination, daemon.io, .{});
            try core.history.appendImage(daemon.io, daemon.allocator, daemon.environ, destination);
        },
        .ocr, .oneline => {
            const profile = try selectedProfile(daemon);
            defer daemon.allocator.free(profile);
            const model_dir = try core.paths.profileDir(daemon.io, daemon.allocator, daemon.environ, profile);
            defer daemon.allocator.free(model_dir);
            const lines = try core.recognizeFile(daemon.allocator, daemon.io, path, .{
                .model_dir = model_dir,
            });
            defer core.freeLines(daemon.allocator, lines);
            const text = try linesToText(daemon.allocator, lines, action == .oneline);
            defer daemon.allocator.free(text);
            if (text.len == 0) return;
            try core.clipboard.copyText(daemon.allocator, daemon.io, daemon.environ, text);
            try core.history.appendText(daemon.io, daemon.allocator, daemon.environ, text);
        },
    }
}

fn selectedProfile(daemon: *Daemon) ![]u8 {
    var parsed = try config.load(daemon.allocator, daemon.io, daemon.environ);
    defer parsed.deinit();
    const selected = parsed.value.models.select orelse "tiny";
    return daemon.allocator.dupe(u8, selected);
}

fn tempPath(daemon: *Daemon) ![]u8 {
    const now = std.Io.Clock.real.now(daemon.io);
    return std.fmt.allocPrint(daemon.allocator, "/tmp/kocr-daemon-{d}.png", .{now.nanoseconds});
}

fn chooseSavePath(daemon: *Daemon) ![]u8 {
    const now = std.Io.Clock.real.now(daemon.io);
    const default = try std.fmt.allocPrint(daemon.allocator, "{s}/kocr-{d}.png", .{
        daemon.environ.get("HOME") orelse ".",
        now.nanoseconds,
    });
    defer daemon.allocator.free(default);

    const result = std.process.run(daemon.allocator, daemon.io, .{
        .argv = &.{ "kdialog", "--getsavefilename", default, "PNG image (*.png)" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return daemon.allocator.alloc(u8, 0);
    defer daemon.allocator.free(result.stdout);
    defer daemon.allocator.free(result.stderr);
    if (!result.term.success()) return daemon.allocator.alloc(u8, 0);
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0) return daemon.allocator.alloc(u8, 0);
    return daemon.allocator.dupe(u8, path);
}

fn linesToText(allocator: std.mem.Allocator, lines: []const core.Line, one_line: bool) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (lines, 0..) |line, index| {
        if (index != 0) try text.append(allocator, if (one_line) ' ' else '\n');
        try text.appendSlice(allocator, line.text);
    }
    return text.toOwnedSlice(allocator);
}

fn notify(daemon: *Daemon, title: []const u8, body: []const u8) void {
    var child = std.process.spawn(daemon.io, .{
        .argv = &.{ "notify-send", "--app-name", "kocr", title, body },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(daemon.io) catch {};
}

pub const DaemonError = error{
    AlreadyRunning,
    DaemonNotFound,
    ProcessControlUnavailable,
};

pub fn lock(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !std.Io.File {
    const dir = try core.config.dir(io, allocator, environ);
    defer allocator.free(dir);
    const path = try std.Io.Dir.path.join(allocator, &.{ dir, "daemon.lock" });
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = false });
    // LOCK_EX | LOCK_NB
    if (std.os.linux.flock(file.handle, 2 | 4) != 0) {
        file.close(io);
        return error.AlreadyRunning;
    }
    return file;
}

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

/// Starts the current executable in daemon mode if the pid file is not live.
pub fn ensureRunning(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    if (try isRunning(io, allocator, environ)) return DaemonError.AlreadyRunning;
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const config_dir = try core.config.dir(io, allocator, environ);
    defer allocator.free(config_dir);
    const log_path = try std.Io.Dir.path.join(allocator, &.{ config_dir, "daemon.log" });
    defer allocator.free(log_path);
    const log_file: ?std.Io.File = std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true }) catch null;
    defer if (log_file) |file| file.close(io);
    const output: std.process.SpawnOptions.StdIo = if (log_file) |file| .{ .file = file } else .ignore;
    var child = std.process.spawn(io, .{
        .argv = &.{ "setsid", "-f", executable, "--daemon" },
        .stdin = .ignore,
        .stdout = output,
        .stderr = output,
    }) catch return error.ProcessControlUnavailable;
    _ = &child;
    std.Io.sleep(io, .{ .nanoseconds = 500 * std.time.ns_per_ms }, .awake) catch {};
    if (!try isRunning(io, allocator, environ)) return DaemonError.ProcessControlUnavailable;
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

pub fn initProcess() void {}
