//! Local OCR history. Text and image entries are stored in one journal;
//! image payloads live in `<data>/kocr/history/`.

const std = @import("std");

const paths = @import("model").paths;

const magic = "KOCR2\n";
const legacy_header_size = 12;
const header_size = 13;

pub const Kind = enum(u8) {
    text = 1,
    image = 2,
};

pub const Content = union(Kind) {
    text: []u8,
    image: []u8,
};

pub const Record = struct {
    created_at: i64,
    content: Content,
};

pub fn historyPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const root = try paths.dataRoot(io, allocator, environ);
    defer allocator.free(root);
    return std.Io.Dir.path.join(allocator, &.{ root, "history.bin" });
}

pub fn imagesDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const root = try paths.dataRoot(io, allocator, environ);
    defer allocator.free(root);
    return std.Io.Dir.path.join(allocator, &.{ root, "history" });
}

pub fn appendText(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    const now = timestamp(io);
    try appendRecord(io, allocator, environ, .{
        .created_at = now,
        .content = .{ .text = @constCast(text) },
    });
}

/// Copies an absolute path into the history image directory.
pub fn appendImage(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    source_path: []const u8,
) !void {
    if (source_path.len == 0) return;
    if (!std.Io.Dir.path.isAbsolute(source_path)) return error.InvalidImagePath;

    const directory = try imagesDir(io, allocator, environ);
    defer allocator.free(directory);
    try std.Io.Dir.cwd().createDirPath(io, directory);

    const now = std.Io.Clock.real.now(io);
    const destination = try std.fmt.allocPrint(allocator, "{s}/{d}.png", .{
        directory,
        now.nanoseconds,
    });
    defer allocator.free(destination);
    try std.Io.Dir.copyFileAbsolute(source_path, destination, io, .{});
    errdefer std.Io.Dir.cwd().deleteFile(io, destination) catch {};

    try appendRecord(io, allocator, environ, .{
        .created_at = timestamp(io),
        .content = .{ .image = @constCast(destination) },
    });
}

pub fn recent(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    limit: usize,
) ![]Record {
    const path = try historyPath(io, allocator, environ);
    defer allocator.free(path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 << 20)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(Record, 0),
        else => return err,
    };
    defer allocator.free(content);

    var records: std.ArrayList(Record) = .empty;
    errdefer freeRecords(allocator, records.items);

    var offset: usize = 0;
    if (std.mem.startsWith(u8, content, magic)) {
        offset = magic.len;
        while (content.len - offset >= header_size) {
            const kind: Kind = std.enums.fromInt(Kind, content[offset]) orelse break;
            const created_at: i64 = @intCast(std.mem.bytesToValue(u64, content[offset + 1 ..][0..8]));
            const length: usize = std.mem.bytesToValue(u32, content[offset + 9 ..][0..4]);
            offset += header_size;
            if (length > content.len - offset) break;
            const payload = try allocator.dupe(u8, content[offset..][0..length]);
            errdefer allocator.free(payload);
            try records.append(allocator, .{
                .created_at = created_at,
                .content = switch (kind) {
                    .text => .{ .text = payload },
                    .image => .{ .image = payload },
                },
            });
            offset += length;
        }
    } else {
        while (content.len - offset >= legacy_header_size) {
            const created_at: i64 = @intCast(std.mem.bytesToValue(u64, content[offset..][0..8]));
            const length: usize = std.mem.bytesToValue(u32, content[offset + 8 ..][0..4]);
            offset += legacy_header_size;
            if (length > content.len - offset) break;
            const text = try allocator.dupe(u8, content[offset..][0..length]);
            errdefer allocator.free(text);
            try records.append(allocator, .{
                .created_at = created_at,
                .content = .{ .text = text },
            });
            offset += length;
        }
    }

    if (records.items.len > limit) {
        const drop = records.items.len - limit;
        for (records.items[0..drop]) |record| freeRecord(allocator, record);
        std.mem.copyForwards(Record, records.items[0..limit], records.items[drop..]);
        records.shrinkRetainingCapacity(limit);
    }
    return records.toOwnedSlice(allocator);
}

pub fn clear(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    const path = try historyPath(io, allocator, environ);
    defer allocator.free(path);
    std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const directory = try imagesDir(io, allocator, environ);
    defer allocator.free(directory);
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
}

pub fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {
    if (records.len == 0) return;
    for (records) |record| freeRecord(allocator, record);
    allocator.free(records);
}

fn freeRecord(allocator: std.mem.Allocator, record: Record) void {
    switch (record.content) {
        .text => |text| allocator.free(text),
        .image => |path| allocator.free(path),
    }
}

fn appendRecord(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    record: Record,
) !void {
    var records = try recent(io, allocator, environ, 500);
    defer freeRecords(allocator, records);
    const start: usize = if (records.len == 500) 1 else 0;

    const path = try historyPath(io, allocator, environ);
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, magic);
    for (records[start..]) |item| try writeRecord(io, file, item);
    try writeRecord(io, file, record);
}

fn writeRecord(io: std.Io, file: std.Io.File, record: Record) !void {
    const payload = switch (record.content) {
        .text => |text| text,
        .image => |path| path,
    };
    var header: [header_size]u8 = undefined;
    header[0] = @backingInt(std.meta.activeTag(record.content));
    @memcpy(header[1..9], std.mem.asBytes(&@as(u64, @intCast(record.created_at))));
    @memcpy(header[9..13], std.mem.asBytes(&@as(u32, @intCast(payload.len))));
    try file.writeStreamingAll(io, &header);
    try file.writeStreamingAll(io, payload);
}

fn timestamp(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    return @intCast(@divTrunc(now.nanoseconds, 1_000_000_000));
}

test "stores and clears image history" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();

    const root = try std.fmt.allocPrint(allocator, "/tmp/kocr-history-test-{d}", .{
        std.Io.Clock.real.now(io).nanoseconds,
    });
    defer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try env.put("XDG_DATA_HOME", root);

    const source = try std.Io.Dir.path.join(allocator, &.{ root, "capture.png" });
    defer allocator.free(source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = "\x89PNG\r\n\x1a\n" });
    try appendImage(io, allocator, &env, source);

    {
        const records = try recent(io, allocator, &env, 10);
        defer freeRecords(allocator, records);
        try std.testing.expectEqual(@as(usize, 1), records.len);
        switch (records[0].content) {
            .image => |path| {
                var file = try std.Io.Dir.cwd().openFile(io, path, .{});
                file.close(io);
            },
            .text => return error.TestUnexpectedResult,
        }
    }

    try clear(io, allocator, &env);
    {
        const records = try recent(io, allocator, &env, 10);
        defer freeRecords(allocator, records);
        try std.testing.expectEqual(@as(usize, 0), records.len);
    }
}
