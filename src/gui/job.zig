//! Platform-independent GUI work: model jobs and OCR post-processing.

const std = @import("std");

const core = @import("core");
const kocr = @import("kocr");

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
    lines: ?[]kocr.Line = null,
    cancelled: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    error_text: ?[]u8 = null,
    thread: ?std.Thread = null,

    pub fn deinit(self: *Job) void {
        if (self.lines) |lines| kocr.freeLines(self.allocator, lines);
        if (self.error_text) |text| self.allocator.free(text);
        self.allocator.free(self.profile);
        if (self.output_path) |path| self.allocator.free(path);
        self.allocator.destroy(self);
    }
};

pub fn worker(job: *Job) void {
    switch (job.kind) {
        .install => {
            _ = kocr.downloader.install(job.io, job.allocator, job.environ, job.profile, .{ .force = false }) catch |err| {
                finishError(job, err);
                return;
            };
        },
        .remove => {
            kocr.downloader.remove(job.io, job.allocator, job.environ, job.profile) catch |err| {
                finishError(job, err);
                return;
            };
        },
        .copy_image, .save_image, .extract, .extract_oneline => {
            const path = job.output_path orelse {
                finishError(job, error.InvalidOutputPath);
                return;
            };
            const capture = core.captureRegion(job.allocator, job.io, path) catch |err| {
                finishError(job, err);
                return;
            };
            if (capture == .cancelled) {
                job.cancelled = true;
                job.done.store(true, .release);
                return;
            }
            if (job.kind == .extract or job.kind == .extract_oneline) {
                const model_dir = kocr.paths.profileDir(job.io, job.allocator, job.environ, job.profile) catch |err| {
                    finishError(job, err);
                    return;
                };
                defer job.allocator.free(model_dir);
                job.lines = kocr.recognizeFile(job.allocator, job.io, path, .{ .model_dir = model_dir }) catch |err| {
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

pub fn linesToText(allocator: std.mem.Allocator, lines: []const kocr.Line, one_line: bool) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (lines, 0..) |line, index| {
        if (index != 0) try text.append(allocator, if (one_line) ' ' else '\n');
        try text.appendSlice(allocator, line.text);
    }
    return text.toOwnedSlice(allocator);
}

pub fn setError(job: *Job, err: anyerror) void {
    job.error_text = std.fmt.allocPrint(job.allocator, "Error: {s}", .{@errorName(err)}) catch null;
}

pub fn formatTime(timestamp: i64) []const u8 {
    const secs: u64 = if (timestamp > 0) @intCast(timestamp) else 0;
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay().calculateYearDay();
    const date = day.calculateMonthDay();
    const parts = epoch.getDaySeconds();
    return std.fmt.bufPrint(&time_buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        day.year,
        date.month.numeric(),
        date.day_index + 1,
        parts.getHoursIntoDay(),
        parts.getMinutesIntoHour(),
    }) catch "---- -- --:--";
}

var time_buffer: [32]u8 = undefined;
