//! Background jobs: model install/remove, capture, OCR, and their polling.

const std = @import("std");

const core = @import("core");
const nui = @import("nanoui");

const history = @import("history.zig");
const model = @import("model.zig");
const state_mod = @import("state.zig");

const State = state_mod.State;

pub const JobKind = enum {
    install,
    remove,
    copy_image,
    save_image,
    extract,
    extract_oneline,
};

pub const Job = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    kind: JobKind,
    profile: []u8,
    output_path: ?[]u8 = null,
    lines: ?[]core.Line = null,
    cancelled: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    progress: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    progress_known: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    error_text: ?[]u8 = null,
    thread: ?std.Thread = null,

    pub fn deinit(self: *Job) void {
        if (self.lines) |lines| core.freeLines(self.allocator, lines);
        if (self.error_text) |text| self.allocator.free(text);
        self.allocator.free(self.profile);
        if (self.output_path) |path| self.allocator.free(path);
        self.allocator.destroy(self);
    }
};

pub fn worker(job: *Job) void {
    switch (job.kind) {
        .install => {
            const installed = core.downloader.install(job.io, job.allocator, job.environ, job.profile, .{
                .force = false,
                .progress = .{ .context = job, .report = reportProgress },
            }) catch |err| {
                finishError(job, err);
                return;
            };
            job.allocator.free(installed);
        },
        .remove => {
            core.downloader.remove(job.io, job.allocator, job.environ, job.profile) catch |err| {
                finishError(job, err);
                return;
            };
        },
        .copy_image, .save_image, .extract, .extract_oneline => {
            const path = job.output_path orelse {
                finishError(job, error.InvalidOutputPath);
                return;
            };
            const capture = core.captureRegion(job.allocator, job.io, job.environ, path) catch |err| {
                finishError(job, err);
                return;
            };
            if (capture == .cancelled) {
                job.cancelled = true;
                job.done.store(true, .release);
                return;
            }
            if (job.kind == .extract or job.kind == .extract_oneline) {
                const model_dir = core.paths.profileDir(job.allocator, job.environ, job.profile) catch |err| {
                    finishError(job, err);
                    return;
                };
                defer job.allocator.free(model_dir);
                job.lines = core.recognizeFile(job.allocator, job.io, path, .{ .model_dir = model_dir }) catch |err| {
                    finishError(job, err);
                    return;
                };
            }
        },
    }
    job.done.store(true, .release);
}

pub fn finishError(job: *Job, err: anyerror) void {
    setError(job, err);
    job.done.store(true, .release);
}

fn reportProgress(context: *anyopaque, downloaded: u64, total: u64) void {
    const job: *Job = @ptrCast(@alignCast(context));
    if (total == 0) return;
    const permille: u32 = @intCast(@min(1000, downloaded * 1000 / total));
    job.progress.store(permille, .release);
    job.progress_known.store(true, .release);
}

pub fn setError(job: *Job, err: anyerror) void {
    job.error_text = std.fmt.allocPrint(job.allocator, "Error: {s}", .{@errorName(err)}) catch null;
}

fn tempPath(state: *State) ?[]u8 {
    const now = std.Io.Clock.real.now(state.io);
    // Must be absolute: history.appendImage refuses relative paths, and
    // TEMP/TMPDIR/TMP are unset on most Linux desktops.
    const temp = nui.path(state.allocator, .temp, core.dirs.name) catch {
        state.setMainStatus("Error: unable to find a temporary directory");
        return null;
    };
    defer state.allocator.free(temp);
    return std.fmt.allocPrint(state.allocator, "{s}{c}kocr-{d}.png", .{
        temp,
        std.Io.Dir.path.sep,
        now.nanoseconds,
    }) catch {
        state.setMainStatus("Error: unable to allocate capture path");
        return null;
    };
}

fn modelKind(kind: JobKind) bool {
    return kind == .install or kind == .remove;
}

fn start(state: *State, kind: JobKind, output_path: ?[]const u8) void {
    if (state.job != null) return;
    const profile = state.allocator.dupe(u8, model.selectedProfile(state)) catch return;
    const owned_path = if (output_path) |path| state.allocator.dupe(u8, path) catch {
        state.allocator.free(profile);
        return;
    } else null;

    const job = state.allocator.create(Job) catch {
        state.allocator.free(profile);
        if (owned_path) |path| state.allocator.free(path);
        return;
    };
    job.* = .{
        .allocator = state.allocator,
        .io = state.io,
        .environ = state.environ,
        .kind = kind,
        .profile = profile,
        .output_path = owned_path,
    };
    state.job = job;
    if (modelKind(kind)) {
        state.setSettingsStatus(if (kind == .install) "Installing model…" else "Removing model…");
    } else {
        state.setMainStatus(switch (kind) {
            .copy_image, .save_image => "Capturing region…",
            .extract, .extract_oneline => "Capturing and recognizing…",
            else => unreachable,
        });
    }
    job.thread = std.Thread.spawn(.{}, worker, .{job}) catch {
        state.job = null;
        if (modelKind(kind)) {
            state.setSettingsStatus("Error: unable to start worker thread");
        } else {
            state.setMainStatus("Error: unable to start worker thread");
        }
        job.deinit();
        return;
    };
    nui.App.after(50, state, jobTimer);
}

pub fn startModel(state: *State, kind: JobKind) void {
    start(state, kind, null);
}

pub fn startCapture(state: *State, kind: JobKind) void {
    const path = tempPath(state) orelse return;
    start(state, kind, path);
    state.allocator.free(path);
}

fn jobTimer(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    const job = state.job orelse return;
    if (!job.done.load(.acquire)) {
        if (job.kind == .install) state.redraw();
        nui.App.after(50, state, jobTimer);
        return;
    }
    finalizeJob(state);
    state.redraw();
}

fn finalizeJob(state: *State) void {
    const job = state.job orelse return;
    if (job.thread) |thread| thread.join();
    state.job = null;

    const error_text = job.error_text;
    job.error_text = null;
    const kind = job.kind;
    const cancelled = job.cancelled;
    const output_path = job.output_path;
    const lines = job.lines;
    job.lines = null;
    job.output_path = null;

    if (error_text) |text| {
        if (modelKind(kind)) {
            state.setSettingsStatus(text);
        } else {
            state.setMainStatus(text);
        }
        state.allocator.free(text);
        if (kind != .save_image) {
            if (output_path) |path| std.Io.Dir.cwd().deleteFile(state.io, path) catch {};
        }
    } else if (cancelled) {
        state.setMainStatus("Capture cancelled");
    } else switch (kind) {
        .install => {
            _ = model.updateModelStatus(state);
            state.setSettingsStatus("Model installed");
        },
        .remove => {
            _ = model.updateModelStatus(state);
            state.setSettingsStatus("Model removed");
        },
        .copy_image => {
            if (output_path) |path| {
                core.clipboard.copyImage(state.allocator, state.io, state.environ, path) catch {};
                core.history.appendImage(state.io, state.allocator, state.environ, path) catch {};
                history.loadHistory(state);
                state.setMainStatus("Screenshot copied");
                _ = std.Io.Dir.cwd().deleteFile(state.io, path) catch {};
            }
        },
        .save_image => {
            if (output_path) |temporary| {
                var name_buffer: [64]u8 = undefined;
                const destination = nui.dialog.save(state.allocator, .{
                    .title = "Save screenshot",
                    .name = core.timestamp.fileName(state.io, &name_buffer, "kocr", "png"),
                    .extensions = &.{"png"},
                }) catch null;
                if (destination) |path| {
                    defer state.allocator.free(path);
                    var saved = true;
                    std.Io.Dir.copyFileAbsolute(temporary, path, state.io, .{}) catch |err| {
                        var buffer: [256]u8 = undefined;
                        state.setMainStatus(std.fmt.bufPrint(&buffer, "Save failed: {s}", .{@errorName(err)}) catch "Save failed");
                        saved = false;
                    };
                    if (saved) {
                        core.history.appendImage(state.io, state.allocator, state.environ, path) catch {};
                        history.loadHistory(state);
                        state.setMainStatus("Screenshot saved");
                    }
                } else {
                    state.setMainStatus("Save cancelled");
                }
                _ = std.Io.Dir.cwd().deleteFile(state.io, temporary) catch {};
            }
        },
        .extract, .extract_oneline => {
            if (lines) |recognized| {
                const text = core.linesToText(state.allocator, recognized, kind == .extract_oneline) catch null;
                if (text) |result| {
                    defer state.allocator.free(result);
                    core.clipboard.copyText(state.allocator, state.io, state.environ, result) catch {};
                    if (result.len != 0) {
                        core.history.appendText(state.io, state.allocator, state.environ, result) catch {};
                    }
                    history.loadHistory(state);
                    state.setMainStatus(if (result.len == 0) "No text found" else "Text copied");
                } else {
                    state.setMainStatus("Error: unable to format text");
                }
                core.freeLines(state.allocator, recognized);
            }
            if (output_path) |path| _ = std.Io.Dir.cwd().deleteFile(state.io, path) catch {};
        },
    }
    if (lines != null and kind != .extract and kind != .extract_oneline) {
        core.freeLines(state.allocator, lines.?);
    }
    if (output_path) |path| state.allocator.free(path);
    job.deinit();
}
