//! Windows daemon: global shortcuts drive capture, OCR, and history.

const std = @import("std");

const config = @import("config");
const core = @import("core");
const kocr = @import("kocr");
const nui = @import("nanoui");

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
    if (!daemon.queue.push(action)) return true;
    return true;
}

fn workerLoop(daemon: *Daemon) void {
    while (daemon.running.load(.acquire)) {
        if (daemon.queue.pop()) |action| {
            runAction(daemon, action) catch |err| {
                _ = nui.dialog.message(.{
                    .title = "kocr action failed",
                    .detail = @errorName(err),
                    .kind = .critical,
                });
            };
        } else {
            std.Io.sleep(daemon.io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
        }
    }
}

fn runAction(daemon: *Daemon, action: core.Action) !void {
    const path = try tempPath(daemon);
    defer daemon.allocator.free(path);
    defer _ = std.Io.Dir.cwd().deleteFile(daemon.io, path) catch {};

    if (try core.captureRegion(daemon.allocator, daemon.io, path) == .cancelled) return;

    switch (action) {
        .copy => {
            try core.clipboard.copyImage(daemon.allocator, daemon.io, daemon.environ, path);
            try kocr.history.appendImage(daemon.io, daemon.allocator, daemon.environ, path);
        },
        .save => {
            const destination = nui.dialog.save(daemon.allocator, .{
                .title = "Save screenshot",
                .name = "kocr.png",
                .extensions = &.{"png"},
            }) catch return;
            const chosen = destination orelse return;
            defer daemon.allocator.free(chosen);
            try std.Io.Dir.copyFileAbsolute(path, chosen, daemon.io, .{});
            try kocr.history.appendImage(daemon.io, daemon.allocator, daemon.environ, chosen);
        },
        .ocr, .oneline => {
            const profile = try selectedProfile(daemon);
            defer daemon.allocator.free(profile);
            const model_dir = try kocr.paths.profileDir(daemon.io, daemon.allocator, daemon.environ, profile);
            defer daemon.allocator.free(model_dir);
            const lines = try kocr.recognizeFile(daemon.allocator, daemon.io, path, .{ .model_dir = model_dir });
            defer kocr.freeLines(daemon.allocator, lines);
            const text = try kocr.linesToText(daemon.allocator, lines, action == .oneline);
            defer daemon.allocator.free(text);
            if (text.len == 0) return;
            try core.clipboard.copyText(daemon.allocator, daemon.io, daemon.environ, text);
            try kocr.history.appendText(daemon.io, daemon.allocator, daemon.environ, text);
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
    const temp = daemon.environ.get("TEMP") orelse daemon.environ.get("TMPDIR") orelse daemon.environ.get("TMP") orelse ".";
    return std.fmt.allocPrint(daemon.allocator, "{s}{c}kocr-daemon-{d}.png", .{
        temp,
        std.Io.Dir.path.sep,
        now.nanoseconds,
    });
}

pub fn run(init: std.process.Init) !void {
    core.daemon_process.acquire(init.io, init.gpa, init.environ_map) catch |err| switch (err) {
        error.AlreadyRunning => return,
        else => return err,
    };
    defer core.daemon_process.release(init.io, init.gpa, init.environ_map);

    var daemon = Daemon{
        .allocator = init.gpa,
        .io = init.io,
        .environ = init.environ_map,
    };
    daemon.worker = try std.Thread.spawn(.{}, workerLoop, .{&daemon});
    defer daemon.stopWorker();

    core.listenConfigured(init.gpa, init.io, init.environ_map, &daemon, handle) catch |err| {
        _ = nui.dialog.message(.{
            .title = "kocr daemon failed",
            .detail = @errorName(err),
            .kind = .critical,
        });
        return err;
    };
}
