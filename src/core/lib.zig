//! Reusable OCR entry points. Callers supply I/O, an allocator, and a model directory.
//! Detection and classification are unloaded before recognition is loaded.

const std = @import("std");

const ocr = @import("ocr.zig");
pub const history = @import("history.zig");

const zignal = @import("zignal");
pub const model = @import("model/model.zig");
pub const paths = model.paths;
pub const downloader = @import("downloader/download.zig");

pub const Image = zignal.Image(zignal.Rgb(u8));
pub const Line = ocr.Line;
pub const TextBox = model.det.TextBox;

/// Paths are borrowed for the duration of the call. Null threads selects up to eight CPUs.
pub const Options = struct {
    model_dir: []const u8,
    threads: ?i32 = null,
    rec_param: ?[]const u8 = null,
    rec_bin: ?[]const u8 = null,
    keys: ?[]const u8 = null,
};

/// Returns owned lines and text; release them with freeLines using the same allocator.
pub fn recognizeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: Options,
) ![]Line {
    var image: Image = try .load(io, allocator, path);
    defer image.deinit(allocator);
    return recognizeImage(allocator, io, image, options);
}

/// Borrows image without modifying it. Returned lines and text belong to the caller.
/// With orientation correction, line bounds refer to the rotated source image.
pub fn recognizeImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    image: Image,
    options: Options,
) ![]Line {
    var files = try ModelFiles.init(allocator, io, options);
    defer files.deinit();

    var detected = blk: {
        var cls = try files.loadClassifier();
        defer if (cls) |*classifier| classifier.deinit();

        var det = try files.loadDetector();
        defer det.deinit();

        break :blk try ocr.detectImage(allocator, io, image, &det, if (cls) |*classifier| classifier else null);
    };
    defer detected.deinit(allocator);

    var rec = try files.loadRecognizer(io);
    defer rec.deinit();
    return ocr.recognizeBoxes(allocator, io, detected.image, detected.boxes, &rec);
}

/// Returns owned boxes; release the slice with allocator.free. No orientation correction.
pub fn detectFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: Options,
) ![]TextBox {
    var files = try ModelFiles.init(allocator, io, options);
    defer files.deinit();
    var det = try files.loadDetector();
    defer det.deinit();
    return det.detectFile(io, path);
}

/// Returns owned text; release it with result.deinit(allocator).
pub fn recognizeLine(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    options: Options,
) !model.rec.Result {
    var files = try ModelFiles.init(allocator, io, options);
    defer files.deinit();
    var rec = try files.loadRecognizer(io);
    defer rec.deinit();
    return rec.recognizeFile(io, path);
}

pub fn freeLines(allocator: std.mem.Allocator, lines: []Line) void {
    ocr.freeLines(allocator, lines);
}

/// A picture's bytes for a list: PNG, scaled to fit `max_side`, so a window can
/// keep many of them instead of a screenful each. The caller frees it.
pub fn previewPng(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_side: u32) ![]u8 {
    var image: Image = try .load(io, allocator, path);
    defer image.deinit(allocator);
    const longest = @max(image.rows, image.cols);
    if (longest <= max_side) return zignal.png.encode(zignal.Rgb(u8), io, allocator, image, .{});

    const scale = @as(f32, @floatFromInt(max_side)) / @as(f32, @floatFromInt(longest));
    const rows: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(image.rows)) * scale))));
    const cols: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(image.cols)) * scale))));
    var small: Image = try .init(allocator, rows, cols);
    defer small.deinit(allocator);
    image.resize(io, allocator, small, .bilinear);
    return zignal.png.encode(zignal.Rgb(u8), io, allocator, small, .{});
}

/// Joins recognized lines with spaces (`one_line`) or newlines.
pub fn linesToText(allocator: std.mem.Allocator, lines: []const Line, one_line: bool) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(allocator);
    for (lines, 0..) |line, index| {
        if (index != 0) try text.append(allocator, if (one_line) ' ' else '\n');
        try text.appendSlice(allocator, line.text);
    }
    return text.toOwnedSlice(allocator);
}

// Keeps manifest-backed tensor names alive until all loaded networks are destroyed.
const ModelFiles = struct {
    allocator: std.mem.Allocator,
    options: Options,
    threads: i32,
    manifest: ?std.json.Parsed(model.Manifest),

    fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !ModelFiles {
        const threads = if (options.threads) |count| blk: {
            if (count <= 0) return error.InvalidThreads;
            break :blk count;
        } else @as(i32, @intCast(@min(std.Thread.getCpuCount() catch 4, 8)));
        return .{
            .allocator = allocator,
            .options = options,
            .threads = threads,
            .manifest = try model.loadManifest(allocator, io, options.model_dir),
        };
    }

    fn deinit(self: *ModelFiles) void {
        if (self.manifest) |*parsed| parsed.deinit();
    }

    fn loadDetector(self: *const ModelFiles) !model.det.Det {
        const names: model.Manifest.Tensor = if (self.manifest) |parsed| parsed.value.det else .{
            .param = "det.param",
            .bin = "det.bin",
            .input = "input",
            .output = "output",
        };
        const param = try resolve(self.allocator, null, self.options.model_dir, names.param);
        defer self.allocator.free(param);
        const bin = try resolve(self.allocator, null, self.options.model_dir, names.bin);
        defer self.allocator.free(bin);
        return model.det.Det.init(self.allocator, .{
            .param = param,
            .bin = bin,
            .input = names.input,
            .output = names.output,
        }, self.threads);
    }

    fn loadRecognizer(self: *const ModelFiles, io: std.Io) !model.rec.Rec {
        const names: model.Manifest.Tensor = if (self.manifest) |parsed| parsed.value.rec else .{
            .param = "rec.param",
            .bin = "rec.bin",
            .input = "input",
            .output = "output",
        };
        const keys_name = if (self.manifest) |parsed| parsed.value.keys else "keys.txt";
        const param = try resolve(self.allocator, self.options.rec_param, self.options.model_dir, names.param);
        defer self.allocator.free(param);
        const bin = try resolve(self.allocator, self.options.rec_bin, self.options.model_dir, names.bin);
        defer self.allocator.free(bin);
        const keys = try resolve(self.allocator, self.options.keys, self.options.model_dir, keys_name);
        defer self.allocator.free(keys);
        return model.rec.Rec.init(self.allocator, io, .{
            .param = param,
            .bin = bin,
            .keys = keys,
            .input = names.input,
            .output = names.output,
        }, self.threads);
    }

    fn loadClassifier(self: *const ModelFiles) !?model.cls.Cls {
        const names = if (self.manifest) |parsed| parsed.value.cls orelse return null else return null;
        const param = try resolve(self.allocator, null, self.options.model_dir, names.param);
        defer self.allocator.free(param);
        const bin = try resolve(self.allocator, null, self.options.model_dir, names.bin);
        defer self.allocator.free(bin);
        return try model.cls.Cls.init(self.allocator, .{
            .param = param,
            .bin = bin,
            .input = names.input,
            .output = names.output,
        }, 1);
    }
};

fn resolve(
    allocator: std.mem.Allocator,
    override: ?[]const u8,
    dir: []const u8,
    name: []const u8,
) ![]u8 {
    if (override) |path| return allocator.dupe(u8, path);
    return std.Io.Dir.path.join(allocator, &.{ dir, name });
}
