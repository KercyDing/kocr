//! PP-OCRv6 text-line recognition.

const std = @import("std");

const ncnn = @import("ncnn");
const zignal = @import("zignal");

const Rgb = zignal.Rgb(u8);

const target_h = 48;

pub const Paths = struct {
    param: []const u8,
    bin: []const u8,
    keys: []const u8,
    input: []const u8 = "input",
    output: []const u8 = "output",
};

pub const Result = struct {
    text: []u8,
    score: f32,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const Rec = struct {
    allocator: std.mem.Allocator,
    net: ncnn.Net,
    keys: [][]const u8,
    keys_buf: []u8,
    input_name: []const u8,
    output_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, paths: Paths, threads: i32) !Rec {
        const keys_buf = try std.Io.Dir.cwd().readFileAlloc(io, paths.keys, allocator, .limited(8 << 20));
        errdefer allocator.free(keys_buf);

        var keys: std.ArrayList([]const u8) = .empty;
        errdefer keys.deinit(allocator);
        const body = if (keys_buf.len != 0 and keys_buf[keys_buf.len - 1] == '\n')
            keys_buf[0 .. keys_buf.len - 1]
        else
            keys_buf;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            try keys.append(allocator, std.mem.trimEnd(u8, line, "\r"));
        }

        var net = try ncnn.Net.init();
        errdefer net.deinit();
        net.setNumThreads(threads);
        try net.loadParamFile(paths.param);
        try net.loadModelFile(paths.bin);

        const owned_keys = try keys.toOwnedSlice(allocator);
        errdefer allocator.free(owned_keys);
        const input_name = try allocator.dupe(u8, paths.input);
        errdefer allocator.free(input_name);
        const output_name = try allocator.dupe(u8, paths.output);
        errdefer allocator.free(output_name);

        return .{
            .allocator = allocator,
            .net = net.move(),
            .keys = owned_keys,
            .keys_buf = keys_buf,
            .input_name = input_name,
            .output_name = output_name,
        };
    }

    pub fn deinit(self: *Rec) void {
        self.allocator.free(self.keys);
        self.allocator.free(self.keys_buf);
        self.allocator.free(self.input_name);
        self.allocator.free(self.output_name);
        self.net.deinit();
    }

    pub fn recognizeFile(self: *Rec, io: std.Io, path: []const u8) !Result {
        var image: zignal.Image(Rgb) = try .load(io, self.allocator, path);
        defer image.deinit(self.allocator);
        return self.recognizeImage(io, image);
    }

    pub fn recognizeImage(self: *Rec, io: std.Io, image: zignal.Image(Rgb)) !Result {
        const ratio = @as(f32, @floatFromInt(target_h)) / @as(f32, @floatFromInt(image.rows));
        const resized_w: u32 = @max(1, @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(image.cols)) * ratio))));
        const input_width: u32 = @max(resized_w, 320);

        var resized: zignal.Image(Rgb) = try .init(self.allocator, target_h, resized_w);
        defer resized.deinit(self.allocator);
        image.resize(io, self.allocator, resized, .lanczos);

        var input = try ncnn.Mat.create3d(input_width, target_h, 3);
        defer input.deinit();
        for (0..3) |c| {
            const plane = try input.channelFloat(c);
            @memset(plane, -1.0);
        }
        for (0..target_h) |y| {
            for (0..resized.cols) |x| {
                const pixel = resized.data[y * resized.stride + x];
                const bgr = [3]u8{ pixel.b, pixel.g, pixel.r };
                for (bgr, 0..) |value, c| {
                    const plane = try input.channelFloat(c);
                    plane[y * input_width + x] = @as(f32, @floatFromInt(value)) / 127.5 - 1.0;
                }
            }
        }

        var ex = try self.net.createExtractor();
        defer ex.deinit();
        try ex.input(self.input_name, input);
        var output = try ex.extract(self.output_name);
        defer output.deinit();

        const rows = output.height();
        const cols = output.width();
        if (self.keys.len != cols) return error.KeyCountMismatch;

        const scores = try output.dataFloat();
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.allocator);

        var total: f32 = 0;
        var chars: usize = 0;
        var previous: usize = 0;
        for (0..rows) |row| {
            const row_scores = scores[row * cols ..][0..cols];
            var best: usize = 0;
            var best_score: f32 = row_scores[0];
            for (row_scores[1..], 1..) |score, index| {
                if (score > best_score) {
                    best_score = score;
                    best = index;
                }
            }
            if (best != 0 and best != previous) {
                try text.appendSlice(self.allocator, self.keys[best]);
                total += best_score;
                chars += 1;
            }
            previous = best;
        }

        const trimmed = std.mem.trim(u8, text.items, " \t\r\n");
        const result_text = try self.allocator.dupe(u8, trimmed);
        text.deinit(self.allocator);
        return .{
            .text = result_text,
            .score = if (chars == 0) 0 else total / @as(f32, @floatFromInt(chars)),
        };
    }
};
