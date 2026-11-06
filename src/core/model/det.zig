//! PP-OCRv6 DB text detection.

const std = @import("std");

const ncnn = @import("ncnn");
const zignal = @import("zignal");

const Rgb = zignal.Rgb(u8);

const max_side: u32 = 768;
const stride: u32 = 32;
const bin_threshold: f32 = 0.2;
const box_threshold: f32 = 0.45;
const unclip_ratio: f32 = 1.4;
const max_candidates: usize = 3000;
const means = [_]f32{ 0.485, 0.456, 0.406 };
const stds = [_]f32{ 0.229, 0.224, 0.225 };

pub const Paths = struct {
    param: []const u8,
    bin: []const u8,
    input: []const u8 = "input",
    output: []const u8 = "output",
};

pub const Point = struct {
    x: f32,
    y: f32,
};

pub const Rect = struct {
    left: u32,
    right: u32,
    top: u32,
    bottom: u32,

    pub fn height(self: Rect) u32 {
        return self.bottom - self.top;
    }
};

pub const TextBox = struct {
    points: [4]Point,
    bounds: Rect,
};

pub const Det = struct {
    allocator: std.mem.Allocator,
    net: ncnn.Net,
    input_name: []const u8,
    output_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, paths: Paths, threads: i32) !Det {
        var net = try ncnn.Net.init();
        errdefer net.deinit();
        net.setNumThreads(threads);
        try net.loadParamFile(paths.param);
        try net.loadModelFile(paths.bin);
        return .{
            .allocator = allocator,
            .net = net,
            .input_name = try allocator.dupe(u8, paths.input),
            .output_name = try allocator.dupe(u8, paths.output),
        };
    }

    pub fn deinit(self: *Det) void {
        self.allocator.free(self.input_name);
        self.allocator.free(self.output_name);
        self.net.deinit();
    }

    pub fn detectFile(self: *Det, io: std.Io, path: []const u8) ![]TextBox {
        var image: zignal.Image(Rgb) = try .load(io, self.allocator, path);
        defer image.deinit(self.allocator);
        return self.detectImage(io, image);
    }

    pub fn detectImage(self: *Det, io: std.Io, image: zignal.Image(Rgb)) ![]TextBox {
        const original_w: u32 = image.cols;
        const original_h: u32 = image.rows;
        if (original_w == 0 or original_h == 0) return error.EmptyImage;

        const longest = @max(original_w, original_h);
        const scale = @min(1.0, @as(f32, @floatFromInt(max_side)) / @as(f32, @floatFromInt(longest)));
        const resized_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(original_w)) * scale + 0.5)));
        const resized_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(original_h)) * scale + 0.5)));
        const padded_w = roundUp(resized_w, stride);
        const padded_h = roundUp(resized_h, stride);

        var resized: zignal.Image(Rgb) = try .init(self.allocator, resized_h, resized_w);
        defer resized.deinit(self.allocator);
        image.resize(io, self.allocator, resized, .lanczos);

        var input = try ncnn.Mat.create3d(padded_w, padded_h, 3);
        defer input.deinit();
        for (0..3) |c| {
            const plane = try input.channelFloat(c);
            @memset(plane, (0.0 - means[c]) / stds[c]);
            const src_width = resized.cols;
            for (0..resized.rows) |y| {
                const row = resized.data[y * resized.stride ..][0..src_width];
                for (row, 0..) |pixel, x| {
                    const value: f32 = @floatFromInt(switch (c) {
                        0 => pixel.b,
                        1 => pixel.g,
                        else => pixel.r,
                    });
                    plane[y * padded_w + x] = (value / 255.0 - means[c]) / stds[c];
                }
            }
        }

        var ex = try self.net.createExtractor();
        defer ex.deinit();
        try ex.input(self.input_name, input);
        var output = try ex.extract(self.output_name);
        defer output.deinit();

        const width = output.width();
        const height = output.height();
        const values = if (output.channels() == 1)
            try output.channelFloat(0)
        else
            return error.UnsupportedOutput;

        return postprocess(self.allocator, values, width, height, .{
            .output_width = width,
            .output_height = height,
            .resized_width = resized_w,
            .resized_height = resized_h,
            .padded_width = padded_w,
            .padded_height = padded_h,
            .original_width = original_w,
            .original_height = original_h,
        });
    }
};

const Geometry = struct {
    output_width: usize,
    output_height: usize,
    resized_width: u32,
    resized_height: u32,
    padded_width: u32,
    padded_height: u32,
    original_width: u32,
    original_height: u32,
};

fn roundUp(value: u32, multiple: u32) u32 {
    return (value + multiple - 1) / multiple * multiple;
}

fn postprocess(
    allocator: std.mem.Allocator,
    values: []const f32,
    width: usize,
    height: usize,
    geometry: Geometry,
) ![]TextBox {
    const pixels = width * height;
    if (values.len < pixels) return error.InvalidOutput;

    var visited = try allocator.alloc(bool, pixels);
    defer allocator.free(visited);
    @memset(visited, false);

    var boxes: std.ArrayList(TextBox) = .empty;
    errdefer boxes.deinit(allocator);

    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(allocator);
    var boundary: std.ArrayList(Point) = .empty;
    defer boundary.deinit(allocator);
    var hull: std.ArrayList(Point) = .empty;
    defer hull.deinit(allocator);

    var candidates: usize = 0;
    outer: for (0..height) |start_y| {
        for (0..width) |start_x| {
            const start = start_y * width + start_x;
            if (visited[start] or values[start] <= bin_threshold) continue;
            if (candidates >= max_candidates) break :outer;
            candidates += 1;

            visited[start] = true;
            queue.clearRetainingCapacity();
            boundary.clearRetainingCapacity();
            try queue.append(allocator, start);

            var head: usize = 0;
            while (head < queue.items.len) : (head += 1) {
                const index = queue.items[head];
                const x = index % width;
                const y = index / width;
                var touches_background = x == 0 or y == 0 or x + 1 >= width or y + 1 >= height;

                const x0 = x -| 1;
                const y0 = y -| 1;
                const x1 = @min(x + 1, width - 1);
                const y1 = @min(y + 1, height - 1);
                var ny = y0;
                while (ny <= y1) : (ny += 1) {
                    var nx = x0;
                    while (nx <= x1) : (nx += 1) {
                        if (nx == x and ny == y) continue;
                        const next = ny * width + nx;
                        if (values[next] <= bin_threshold) {
                            touches_background = true;
                            continue;
                        }
                        if (visited[next]) continue;
                        visited[next] = true;
                        try queue.append(allocator, next);
                    }
                }
                if (touches_background) {
                    try boundary.append(allocator, .{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
                }
            }

            if (boundary.items.len < 3) continue;
            const hull_points = try convexHullInPlace(allocator, &boundary, &hull);
            if (hull_points.len < 3) continue;

            const box = minAreaRect(hull_points) orelse continue;
            if (2 * @min(box.half_u, box.half_v) < 3.0) continue;
            if (boxScore(values, width, height, box) < box_threshold) continue;

            const expanded = unclip(box);
            if (2 * @min(expanded.half_u, expanded.half_v) < 5.0) continue;

            try boxes.append(allocator, mapQuad(expanded, geometry));
        }
    }
    return boxes.toOwnedSlice(allocator);
}

fn convexHullInPlace(allocator: std.mem.Allocator, points: *std.ArrayList(Point), hull: *std.ArrayList(Point)) ![]Point {
    std.mem.sort(Point, points.items, {}, pointLessThan);
    hull.clearRetainingCapacity();

    for (points.items) |point| {
        while (hull.items.len >= 2 and cross(hull.items[hull.items.len - 2], hull.items[hull.items.len - 1], point) <= 0)
            _ = hull.pop();
        try hull.append(allocator, point);
    }
    const lower_len = hull.items.len;
    var i: usize = points.items.len - 1;
    while (i > 0) : (i -= 1) {
        const point = points.items[i - 1];
        while (hull.items.len > lower_len and cross(hull.items[hull.items.len - 2], hull.items[hull.items.len - 1], point) <= 0)
            _ = hull.pop();
        try hull.append(allocator, point);
    }
    if (hull.items.len > 1) _ = hull.pop();
    return hull.items;
}

fn pointLessThan(_: void, a: Point, b: Point) bool {
    return if (a.x == b.x) a.y < b.y else a.x < b.x;
}

fn cross(a: Point, b: Point, c: Point) f32 {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
}

const Box = struct {
    cx: f32,
    cy: f32,
    ux: f32,
    uy: f32,
    vx: f32,
    vy: f32,
    half_u: f32,
    half_v: f32,
};

fn minAreaRect(hull: []const Point) ?Box {
    var best_area = std.math.inf(f32);
    var best: Box = undefined;
    var found = false;

    for (hull, 0..) |a, index| {
        const b = hull[(index + 1) % hull.len];
        const edge_x = b.x - a.x;
        const edge_y = b.y - a.y;
        const length = @sqrt(edge_x * edge_x + edge_y * edge_y);
        if (length < 1e-6) continue;
        const ux = edge_x / length;
        const uy = edge_y / length;
        const vx = -uy;
        const vy = ux;

        var min_u = std.math.inf(f32);
        var max_u = -std.math.inf(f32);
        var min_v = std.math.inf(f32);
        var max_v = -std.math.inf(f32);
        for (hull) |point| {
            const pu = point.x * ux + point.y * uy;
            const pv = point.x * vx + point.y * vy;
            min_u = @min(min_u, pu);
            max_u = @max(max_u, pu);
            min_v = @min(min_v, pv);
            max_v = @max(max_v, pv);
        }
        const area = (max_u - min_u) * (max_v - min_v);
        if (area < best_area) {
            best_area = area;
            found = true;
            const center_u = (min_u + max_u) * 0.5;
            const center_v = (min_v + max_v) * 0.5;
            best = .{
                .cx = ux * center_u + vx * center_v,
                .cy = uy * center_u + vy * center_v,
                .ux = ux,
                .uy = uy,
                .vx = vx,
                .vy = vy,
                .half_u = (max_u - min_u) * 0.5,
                .half_v = (max_v - min_v) * 0.5,
            };
        }
    }
    return if (found) best else null;
}

fn boxScore(values: []const f32, width: usize, height: usize, box: Box) f32 {
    const min_x = box.cx - box.half_u * @abs(box.ux) - box.half_v * @abs(box.vx);
    const max_x = box.cx + box.half_u * @abs(box.ux) + box.half_v * @abs(box.vx);
    const min_y = box.cy - box.half_u * @abs(box.uy) - box.half_v * @abs(box.vy);
    const max_y = box.cy + box.half_u * @abs(box.uy) + box.half_v * @abs(box.vy);

    const x0: usize = @intFromFloat(std.math.clamp(@floor(min_x), 0, @as(f32, @floatFromInt(width - 1))));
    const x1: usize = @intFromFloat(std.math.clamp(@ceil(max_x), 0, @as(f32, @floatFromInt(width - 1))));
    const y0: usize = @intFromFloat(std.math.clamp(@floor(min_y), 0, @as(f32, @floatFromInt(height - 1))));
    const y1: usize = @intFromFloat(std.math.clamp(@ceil(max_y), 0, @as(f32, @floatFromInt(height - 1))));

    var sum: f32 = 0;
    var count: usize = 0;
    for (y0..y1 + 1) |y| {
        const py = @as(f32, @floatFromInt(y)) + 0.5 - box.cy;
        for (x0..x1 + 1) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5 - box.cx;
            const du = px * box.ux + py * box.uy;
            if (@abs(du) > box.half_u) continue;
            const dv = px * box.vx + py * box.vy;
            if (@abs(dv) > box.half_v) continue;
            sum += values[y * width + x];
            count += 1;
        }
    }
    return if (count == 0) 0 else sum / @as(f32, @floatFromInt(count));
}

fn unclip(box: Box) Box {
    const area = 4 * box.half_u * box.half_v;
    const perimeter = 4 * (box.half_u + box.half_v);
    if (area <= 0 or perimeter <= 0) return box;
    const expand = area * unclip_ratio / perimeter;
    return .{
        .cx = box.cx,
        .cy = box.cy,
        .ux = box.ux,
        .uy = box.uy,
        .vx = box.vx,
        .vy = box.vy,
        .half_u = box.half_u + expand,
        .half_v = box.half_v + expand,
    };
}

fn mapQuad(box: Box, geometry: Geometry) TextBox {
    const scale_x = @as(f32, @floatFromInt(geometry.original_width * geometry.padded_width)) /
        @as(f32, @floatFromInt(geometry.resized_width * @as(u32, @intCast(geometry.output_width))));
    const scale_y = @as(f32, @floatFromInt(geometry.original_height * geometry.padded_height)) /
        @as(f32, @floatFromInt(geometry.resized_height * @as(u32, @intCast(geometry.output_height))));

    const offsets = [4][2]f32{
        .{ -1, -1 },
        .{ 1, -1 },
        .{ 1, 1 },
        .{ -1, 1 },
    };
    var mapped: [4]Point = undefined;
    var left: f32 = @floatFromInt(geometry.original_width);
    var top: f32 = @floatFromInt(geometry.original_height);
    var right: f32 = 0;
    var bottom: f32 = 0;

    for (offsets, 0..) |offset, index| {
        const u = box.half_u * offset[0];
        const v = box.half_v * offset[1];
        const point = Point{
            .x = std.math.clamp((box.cx + box.ux * u + box.vx * v) * scale_x, 0, @as(f32, @floatFromInt(geometry.original_width))),
            .y = std.math.clamp((box.cy + box.uy * u + box.vy * v) * scale_y, 0, @as(f32, @floatFromInt(geometry.original_height))),
        };
        mapped[index] = point;
        left = @min(left, point.x);
        top = @min(top, point.y);
        right = @max(right, point.x);
        bottom = @max(bottom, point.y);
    }

    const left_u: u32 = @intFromFloat(@round(left));
    const top_u: u32 = @intFromFloat(@round(top));
    const right_u: u32 = @min(@max(@as(u32, @intFromFloat(@round(right))), left_u + 1), geometry.original_width);
    const bottom_u: u32 = @min(@max(@as(u32, @intFromFloat(@round(bottom))), top_u + 1), geometry.original_height);

    return .{
        .points = mapped,
        .bounds = .{ .left = left_u, .right = right_u, .top = top_u, .bottom = bottom_u },
    };
}
