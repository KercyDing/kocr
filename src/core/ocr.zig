//! Full-image OCR pipeline: detection, line grouping, orientation, recognition.

const std = @import("std");

const zignal = @import("zignal");
const model = @import("model/model.zig");

const crop_padding_x: f32 = 0.06;
const crop_padding_y: f32 = 0.05;
pub const Line = struct {
    text: []u8,
    score: f32,
    bounds: model.det.Rect,
};

const LineGroup = struct {
    top: f32,
    bottom: f32,
    center: f32,
    cx: f32,
    cy: f32,
    ux: f32,
    uy: f32,
    vx: f32,
    vy: f32,
    half_w: f32,
    half_h: f32,
    boxes: std.ArrayList(usize) = .empty,
};

const BoxGeometry = struct {
    cx: f32,
    cy: f32,
    ux: f32,
    uy: f32,
    vx: f32,
    vy: f32,
    half_w: f32,
    half_h: f32,
};

fn boxGeometry(box: model.det.TextBox) BoxGeometry {
    const points = orderBoxPoints(box.points);
    const width = @max(distance(points[0], points[1]), 1e-3);
    const height = @max(distance(points[0], points[3]), 1e-3);
    return .{
        .cx = (points[0].x + points[2].x) * 0.5,
        .cy = (points[0].y + points[2].y) * 0.5,
        .ux = (points[1].x - points[0].x) / width,
        .uy = (points[1].y - points[0].y) / width,
        .vx = (points[3].x - points[0].x) / height,
        .vy = (points[3].y - points[0].y) / height,
        .half_w = width * 0.5,
        .half_h = height * 0.5,
    };
}

pub const Detection = struct {
    image: zignal.Image(zignal.Rgb(u8)),
    boxes: []model.det.TextBox,
    owned_image: bool,

    pub fn deinit(self: *Detection, allocator: std.mem.Allocator) void {
        allocator.free(self.boxes);
        if (self.owned_image) self.image.deinit(allocator);
    }
};

pub fn detectImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    image: zignal.Image(zignal.Rgb(u8)),
    det: *model.det.Det,
    cls: ?*model.cls.Cls,
) !Detection {
    const boxes = try det.detectImage(io, image);
    errdefer allocator.free(boxes);
    std.mem.sort(model.det.TextBox, boxes, {}, boxLessThan);

    var groups = try buildGroups(allocator, boxes);
    defer freeGroups(allocator, &groups);

    if (cls) |classifier| {
        var rot_weight: f32 = 0;
        var no_rot_weight: f32 = 0;
        for (groups.items) |*group| {
            var crop = try groupCrop(io, allocator, image, boxes, group.boxes.items);
            defer crop.deinit(allocator);
            const result = try classifier.classify(io, crop);
            if (result.is_rot) rot_weight += result.score else no_rot_weight += result.score;
        }
        if (rot_weight > no_rot_weight) {
            var rotated = try rotate180(io, allocator, image);
            errdefer rotated.deinit(allocator);
            const rotated_boxes = try det.detectImage(io, rotated);
            std.mem.sort(model.det.TextBox, rotated_boxes, {}, boxLessThan);
            allocator.free(boxes);
            return .{ .image = rotated, .boxes = rotated_boxes, .owned_image = true };
        }
    }

    return .{ .image = image, .boxes = boxes, .owned_image = false };
}

pub fn recognizeBoxes(
    allocator: std.mem.Allocator,
    io: std.Io,
    image: zignal.Image(zignal.Rgb(u8)),
    boxes: []model.det.TextBox,
    rec: *model.rec.Rec,
) ![]Line {
    std.mem.sort(model.det.TextBox, boxes, {}, boxLessThan);

    var lines: std.ArrayList(Line) = .empty;
    errdefer freeLines(allocator, lines.items);
    for (boxes) |box| {
        var crop = try cropBox(io, allocator, image, box);
        defer crop.deinit(allocator);
        const result = try rec.recognizeImage(io, crop);
        if (result.text.len == 0 or result.score < 0.5) {
            allocator.free(result.text);
            continue;
        }
        try lines.append(allocator, .{
            .text = result.text,
            .score = result.score,
            .bounds = box.bounds,
        });
    }
    if (lines.items.len == 0) {
        const result = try rec.recognizeImage(io, image);
        if (result.text.len != 0) {
            const width: u32 = @intCast(image.cols);
            const height: u32 = @intCast(image.rows);
            try lines.append(allocator, .{
                .text = result.text,
                .score = result.score,
                .bounds = .{ .left = 0, .right = width, .top = 0, .bottom = height },
            });
        } else {
            allocator.free(result.text);
        }
    }
    return lines.toOwnedSlice(allocator);
}

fn buildGroups(allocator: std.mem.Allocator, boxes: []const model.det.TextBox) !std.ArrayList(LineGroup) {
    var groups: std.ArrayList(LineGroup) = .empty;
    errdefer freeGroups(allocator, &groups);

    for (boxes, 0..) |box, index| {
        const top: f32 = @floatFromInt(box.bounds.top);
        const bottom: f32 = @floatFromInt(box.bounds.bottom);
        const geometry = boxGeometry(box);
        var matched: ?*LineGroup = null;
        for (groups.items) |*group| {
            const dot = geometry.ux * group.ux + geometry.uy * group.uy;
            if (dot < 0.98) continue;
            const dx = geometry.cx - group.cx;
            const dy = geometry.cy - group.cy;
            const perpendicular = @abs(dx * group.vx + dy * group.vy);
            if (perpendicular > 0.5 * @max(geometry.half_h, group.half_h)) continue;
            const along = @abs(dx * group.ux + dy * group.uy);
            const reach = geometry.half_w + group.half_w + @max(geometry.half_h, group.half_h);
            if (along <= reach) {
                matched = group;
                break;
            }
        }
        if (matched) |group| {
            try group.boxes.append(allocator, index);
            group.top = @min(group.top, top);
            group.bottom = @max(group.bottom, bottom);
            group.center = (group.top + group.bottom) * 0.5;
        } else {
            var group = LineGroup{
                .top = top,
                .bottom = bottom,
                .center = (top + bottom) * 0.5,
                .cx = geometry.cx,
                .cy = geometry.cy,
                .ux = geometry.ux,
                .uy = geometry.uy,
                .vx = geometry.vx,
                .vy = geometry.vy,
                .half_w = geometry.half_w,
                .half_h = geometry.half_h,
            };
            try group.boxes.append(allocator, index);
            try groups.append(allocator, group);
        }
    }
    std.mem.sort(LineGroup, groups.items, {}, groupLessThan);
    return groups;
}

fn freeGroups(allocator: std.mem.Allocator, groups: *std.ArrayList(LineGroup)) void {
    for (groups.items) |*group| group.boxes.deinit(allocator);
    groups.deinit(allocator);
}

fn cropLine(
    io: std.Io,
    allocator: std.mem.Allocator,
    image: zignal.Image(zignal.Rgb(u8)),
    boxes: []const model.det.TextBox,
    indices: []const usize,
) !zignal.Image(zignal.Rgb(u8)) {
    const first = boxGeometry(boxes[indices[0]]);
    const ux = first.ux;
    const uy = first.uy;
    const vx = first.vx;
    const vy = first.vy;

    var min_u = std.math.inf(f32);
    var max_u = -std.math.inf(f32);
    var min_v = std.math.inf(f32);
    var max_v = -std.math.inf(f32);
    for (indices) |index| {
        const points = orderBoxPoints(boxes[index].points);
        for (points) |point| {
            const pu = point.x * ux + point.y * uy;
            const pv = point.x * vx + point.y * vy;
            min_u = @min(min_u, pu);
            max_u = @max(max_u, pu);
            min_v = @min(min_v, pv);
            max_v = @max(max_v, pv);
        }
    }

    const height = @max(max_v - min_v + 4, 2);
    const width = @max(max_u - min_u + 4, 2);
    const out_w: u32 = @max(1, @as(u32, @intFromFloat(@round(width))));
    const out_h: u32 = @max(1, @as(u32, @intFromFloat(@round(height))));
    const center_u = (min_u + max_u) * 0.5;
    const center_v = (min_v + max_v) * 0.5;
    const cx = ux * center_u + vx * center_v;
    const cy = uy * center_u + vy * center_v;
    const angle = std.math.atan2(uy, ux);

    var crop: zignal.Image(zignal.Rgb(u8)) = try .init(allocator, out_h, out_w);
    errdefer crop.deinit(allocator);
    image.extract(io, crop, .{
        .l = cx - @as(f32, @floatFromInt(out_w)) * 0.5,
        .t = cy - @as(f32, @floatFromInt(out_h)) * 0.5,
        .r = cx + @as(f32, @floatFromInt(out_w)) * 0.5,
        .b = cy + @as(f32, @floatFromInt(out_h)) * 0.5,
    }, angle, .lanczos, .replicate);

    if (crop.rows >= crop.cols * 3 / 2) {
        const rotated = try crop.rotate(io, allocator, std.math.pi / 2.0, .nearest, .zero, .expand);
        crop.deinit(allocator);
        return rotated;
    }
    return crop;
}

fn groupCrop(
    io: std.Io,
    allocator: std.mem.Allocator,
    image: zignal.Image(zignal.Rgb(u8)),
    boxes: []const model.det.TextBox,
    indices: []const usize,
) !zignal.Image(zignal.Rgb(u8)) {
    if (indices.len == 1) return cropBox(io, allocator, image, boxes[indices[0]]);
    return cropLine(io, allocator, image, boxes, indices);
}

fn rotate180(
    io: std.Io,
    allocator: std.mem.Allocator,
    image: zignal.Image(zignal.Rgb(u8)),
) !zignal.Image(zignal.Rgb(u8)) {
    return image.rotate(io, allocator, std.math.pi, .nearest, .zero, .expand);
}

fn cropBox(
    io: std.Io,
    allocator: std.mem.Allocator,
    image: zignal.Image(zignal.Rgb(u8)),
    box: model.det.TextBox,
) !zignal.Image(zignal.Rgb(u8)) {
    const points = orderBoxPoints(box.points);
    const width = distance(points[0], points[1]) * (1 + 2 * crop_padding_x);
    const height = distance(points[0], points[3]) * (1 + 2 * crop_padding_y);
    if (width < 2 or height < 2) {
        const bounds = box.bounds;
        return image.crop(io, allocator, .{
            .l = @floatFromInt(bounds.left),
            .t = @floatFromInt(bounds.top),
            .r = @floatFromInt(bounds.right),
            .b = @floatFromInt(bounds.bottom),
        });
    }

    const out_w: u32 = @max(1, @as(u32, @intFromFloat(@round(width))));
    const out_h: u32 = @max(1, @as(u32, @intFromFloat(@round(height))));
    const cx = (points[0].x + points[2].x) * 0.5;
    const cy = (points[0].y + points[2].y) * 0.5;
    const angle = std.math.atan2(points[1].y - points[0].y, points[1].x - points[0].x);

    var crop: zignal.Image(zignal.Rgb(u8)) = try .init(allocator, out_h, out_w);
    errdefer crop.deinit(allocator);
    image.extract(io, crop, .{
        .l = cx - @as(f32, @floatFromInt(out_w)) * 0.5,
        .t = cy - @as(f32, @floatFromInt(out_h)) * 0.5,
        .r = cx + @as(f32, @floatFromInt(out_w)) * 0.5,
        .b = cy + @as(f32, @floatFromInt(out_h)) * 0.5,
    }, angle, .bilinear, .replicate);

    if (crop.rows >= crop.cols * 3 / 2) {
        const rotated = try crop.rotate(io, allocator, std.math.pi / 2.0, .nearest, .zero, .expand);
        crop.deinit(allocator);
        return rotated;
    }
    return crop;
}

fn orderBoxPoints(points: [4]model.det.Point) [4]model.det.Point {
    var sorted = points;
    std.mem.sort(model.det.Point, &sorted, {}, pointLessThan);
    const idx0: usize = if (sorted[1].y > sorted[0].y) 0 else 1;
    const idx3: usize = 1 - idx0;
    const idx1: usize = if (sorted[3].y > sorted[2].y) 2 else 3;
    const idx2: usize = 5 - idx1;
    return .{ sorted[idx0], sorted[idx1], sorted[idx2], sorted[idx3] };
}

fn pointLessThan(_: void, a: model.det.Point, b: model.det.Point) bool {
    return a.x < b.x;
}

fn distance(a: model.det.Point, b: model.det.Point) f32 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

fn boxLessThan(_: void, a: model.det.TextBox, b: model.det.TextBox) bool {
    const tolerance = @max(
        @max(@as(f32, @floatFromInt(a.bounds.height())), @as(f32, @floatFromInt(b.bounds.height()))) * 0.5,
        8,
    );
    const top_delta = @abs(@as(f32, @floatFromInt(a.bounds.top)) - @as(f32, @floatFromInt(b.bounds.top)));
    if (top_delta <= tolerance) return a.bounds.left < b.bounds.left;
    return a.bounds.top < b.bounds.top;
}

fn groupLessThan(_: void, a: LineGroup, b: LineGroup) bool {
    return a.center < b.center;
}

pub fn freeLines(allocator: std.mem.Allocator, lines: []Line) void {
    for (lines) |line| allocator.free(line.text);
    allocator.free(lines);
}

fn axisBox(left: u32, top: u32, right: u32, bottom: u32) model.det.TextBox {
    const l: f32 = @floatFromInt(left);
    const t: f32 = @floatFromInt(top);
    const r: f32 = @floatFromInt(right);
    const b: f32 = @floatFromInt(bottom);
    return .{
        .points = .{ .{ .x = l, .y = t }, .{ .x = r, .y = t }, .{ .x = r, .y = b }, .{ .x = l, .y = b } },
        .bounds = .{ .left = left, .right = right, .top = top, .bottom = bottom },
    };
}

fn rotateBox(box: model.det.TextBox, radians: f32) model.det.TextBox {
    const center = boxGeometry(box);
    const sin = @sin(radians);
    const cos = @cos(radians);
    var points: [4]model.det.Point = undefined;
    for (box.points, 0..) |p, i| {
        const dx = p.x - center.cx;
        const dy = p.y - center.cy;
        points[i] = .{ .x = center.cx + dx * cos - dy * sin, .y = center.cy + dx * sin + dy * cos };
    }
    return .{ .points = points, .bounds = box.bounds };
}

test "orderBoxPoints recovers corners from any input order" {
    const expected = [4]model.det.Point{
        .{ .x = 0, .y = 10 }, .{ .x = 40, .y = 10 }, .{ .x = 40, .y = 30 }, .{ .x = 0, .y = 30 },
    };
    // All 24 permutations.
    for (0..4) |a| {
        for (0..4) |b| {
            if (b == a) continue;
            for (0..4) |c| {
                if (c == a or c == b) continue;
                const d: usize = 6 - a - b - c;
                const ordered = orderBoxPoints(.{ expected[a], expected[b], expected[c], expected[d] });
                for (ordered, expected) |got, want| {
                    try std.testing.expectEqual(want.x, got.x);
                    try std.testing.expectEqual(want.y, got.y);
                }
            }
        }
    }
}

test "boxGeometry of an axis-aligned box" {
    const g = boxGeometry(axisBox(6, 18, 14, 22));
    try std.testing.expectEqual(10.0, g.cx);
    try std.testing.expectEqual(20.0, g.cy);
    try std.testing.expectEqual(4.0, g.half_w);
    try std.testing.expectEqual(2.0, g.half_h);
    try std.testing.expectEqual(@as(f32, 1), g.ux);
    try std.testing.expectEqual(@as(f32, 0), g.uy);
    try std.testing.expectEqual(@as(f32, 0), g.vx);
    try std.testing.expectEqual(@as(f32, 1), g.vy);
}

test "boxGeometry follows a rotated box" {
    // 3-4-5 triangle: 4 wide, 3 tall, baseline slope 3/4.
    const box = model.det.TextBox{
        .points = .{
            .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 3 }, .{ .x = 1, .y = 7 }, .{ .x = -3, .y = 4 },
        },
        .bounds = .{ .left = 0, .right = 4, .top = 0, .bottom = 7 },
    };
    const g = boxGeometry(box);
    try std.testing.expectEqual(@as(f32, 0.8), g.ux);
    try std.testing.expectEqual(@as(f32, 0.6), g.uy);
    try std.testing.expectApproxEqAbs(@as(f32, -0.6), g.vx, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), g.vy, 1e-6);
}

test "buildGroups joins boxes on one line" {
    const allocator = std.testing.allocator;
    const boxes = [_]model.det.TextBox{ axisBox(0, 0, 100, 20), axisBox(100, 0, 200, 20) };
    var groups = try buildGroups(allocator, &boxes);
    defer freeGroups(allocator, &groups);
    try std.testing.expectEqual(1, groups.items.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, groups.items[0].boxes.items);
}

test "buildGroups joins up to the horizontal reach" {
    const allocator = std.testing.allocator;
    // reach = half_w + half_w + half_h = 50 + 50 + 10, measured between centers.
    inline for (.{ .{ 110, 1 }, .{ 111, 2 } }) |case| {
        const boxes = [_]model.det.TextBox{ axisBox(0, 0, 100, 20), axisBox(case[0], 0, case[0] + 100, 20) };
        var groups = try buildGroups(allocator, &boxes);
        defer freeGroups(allocator, &groups);
        try std.testing.expectEqual(@as(usize, case[1]), groups.items.len);
    }
}

test "buildGroups splits past half the line height" {
    const allocator = std.testing.allocator;
    // perpendicular = 5 joins, 6 splits.
    inline for (.{ .{ 5, 1 }, .{ 6, 2 } }) |case| {
        const boxes = [_]model.det.TextBox{ axisBox(0, 0, 100, 20), axisBox(0, case[0], 100, 20 + case[0]) };
        var groups = try buildGroups(allocator, &boxes);
        defer freeGroups(allocator, &groups);
        try std.testing.expectEqual(@as(usize, case[1]), groups.items.len);
    }
}

test "buildGroups splits lines past the angle tolerance" {
    const allocator = std.testing.allocator;
    const line = axisBox(0, 0, 100, 20);
    // dot = cos(angle); 5 degrees is 0.996, 20 degrees is 0.940.
    const cases = .{ .{ 5.0, 1 }, .{ 20.0, 2 } };
    inline for (cases) |case| {
        const boxes = [_]model.det.TextBox{ line, rotateBox(line, case[0] * std.math.pi / 180.0) };
        var groups = try buildGroups(allocator, &boxes);
        defer freeGroups(allocator, &groups);
        try std.testing.expectEqual(@as(usize, case[1]), groups.items.len);
    }
}

test "buildGroups grows the line bounds when joining" {
    const allocator = std.testing.allocator;
    const boxes = [_]model.det.TextBox{ axisBox(0, 0, 100, 20), axisBox(0, 4, 100, 24) };
    var groups = try buildGroups(allocator, &boxes);
    defer freeGroups(allocator, &groups);
    try std.testing.expectEqual(1, groups.items.len);
    try std.testing.expectEqual(@as(f32, 0), groups.items[0].top);
    try std.testing.expectEqual(@as(f32, 24), groups.items[0].bottom);
    try std.testing.expectEqual(@as(f32, 12), groups.items[0].center);
}

test "boxLessThan orders by column within a row, by row otherwise" {
    const tall_a = axisBox(0, 0, 10, 10);
    const tall_b = axisBox(20, 8, 30, 18); // top delta 8, tolerance 8: same row
    const tall_c = axisBox(5, 9, 15, 19); // top delta 9: next row
    try std.testing.expect(boxLessThan({}, tall_a, tall_b));
    try std.testing.expect(!boxLessThan({}, tall_b, tall_a));
    try std.testing.expect(boxLessThan({}, tall_a, tall_c));
    try std.testing.expect(!boxLessThan({}, tall_c, tall_a));

    // The tolerance floor is 8, so short boxes still compare by column.
    const short_a = axisBox(0, 0, 10, 4);
    const short_b = axisBox(20, 6, 30, 10);
    try std.testing.expect(boxLessThan({}, short_a, short_b));
    try std.testing.expect(!boxLessThan({}, short_b, short_a));
}
