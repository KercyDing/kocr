//! PP-LCNet text-line orientation classifier.

const std = @import("std");

const ncnn = @import("ncnn");
const zignal = @import("zignal");

const Rgb = zignal.Rgb(u8);

const target_w: u32 = 160;
const target_h: u32 = 80;
const max_downscale: f32 = 3.0;

pub const Paths = struct {
    param: []const u8,
    bin: []const u8,
    input: []const u8 = "input",
    output: []const u8 = "output",
};

pub const Result = struct {
    is_rot: bool,
    score: f32,
};

pub const Cls = struct {
    allocator: std.mem.Allocator,
    net: ncnn.Net,
    input_name: []const u8,
    output_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, paths: Paths, threads: i32) !Cls {
        var net = try ncnn.Net.init();
        errdefer net.deinit();
        net.setNumThreads(threads);
        try net.loadParamFile(paths.param);
        try net.loadModelFile(paths.bin);

        const input_name = try allocator.dupe(u8, paths.input);
        errdefer allocator.free(input_name);
        const output_name = try allocator.dupe(u8, paths.output);
        errdefer allocator.free(output_name);

        return .{
            .allocator = allocator,
            .net = net.move(),
            .input_name = input_name,
            .output_name = output_name,
        };
    }

    pub fn deinit(self: *Cls) void {
        self.allocator.free(self.input_name);
        self.allocator.free(self.output_name);
        self.net.deinit();
    }

    pub fn classify(self: *Cls, io: std.Io, image: zignal.Image(Rgb)) !Result {
        if (image.rows == 0 or image.cols == 0) return .{ .is_rot = false, .score = 0 };

        const ratio = @as(f32, @floatFromInt(target_h)) / @as(f32, @floatFromInt(image.rows));
        const resized_w: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(image.cols)) * ratio))));

        var resized: zignal.Image(Rgb) = try .init(self.allocator, target_h, @min(resized_w, target_w));
        defer resized.deinit(self.allocator);

        if (resized_w < target_w) {
            var narrow: zignal.Image(Rgb) = try .init(self.allocator, target_h, resized_w);
            defer narrow.deinit(self.allocator);
            image.resize(io, self.allocator, narrow, .lanczos);
            for (0..target_h) |y| {
                @memcpy(resized.data[y * resized.stride ..][0..narrow.cols], narrow.data[y * narrow.stride ..][0..narrow.cols]);
            }
        } else if (resized_w < @as(u32, @intFromFloat(target_w * max_downscale))) {
            image.resize(io, self.allocator, resized, .lanczos);
        } else {
            const crop_w = @min(image.cols, @as(u32, @intFromFloat(max_downscale * @as(f32, @floatFromInt(target_w)) / ratio)));
            var crop = try image.crop(io, self.allocator, .{
                .l = 0,
                .t = 0,
                .r = @floatFromInt(crop_w),
                .b = @floatFromInt(image.rows),
            });
            defer crop.deinit(self.allocator);
            crop.resize(io, self.allocator, resized, .lanczos);
        }

        var input = try ncnn.Mat.create3d(target_w, target_h, 3);
        defer input.deinit();
        for (0..3) |c| {
            const plane = try input.channelFloat(c);
            @memset(plane, (114.0 - 127.5) / 127.5);
        }
        for (0..target_h) |y| {
            for (0..resized.cols) |x| {
                const pixel = resized.data[y * resized.stride + x];
                const bgr = [3]u8{ pixel.b, pixel.g, pixel.r };
                for (bgr, 0..) |value, c| {
                    const plane = try input.channelFloat(c);
                    plane[y * target_w + x] = (@as(f32, @floatFromInt(value)) - 127.5) / 127.5;
                }
            }
        }

        var ex = try self.net.createExtractor();
        defer ex.deinit();
        try ex.input(self.input_name, input);
        var output = try ex.extract(self.output_name);
        defer output.deinit();
        const scores = try output.dataFloat();
        if (scores.len < 2) return .{ .is_rot = false, .score = 0 };
        const index: usize = if (scores[1] > scores[0]) 1 else 0;
        const score = @max(scores[0], scores[1]);
        return .{ .is_rot = index == 1, .score = score };
    }
};
