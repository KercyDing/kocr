//! Minimal local OCR history. Entries are timestamped text; consumers own the
//! returned records until freeRecords is called.

const std = @import("std");

const paths = @import("model").paths;

pub const Record = struct {
    created_at: i64,
    text: []u8,
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

pub fn appendText(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    text: []const u8,
) !void {
    if (text.len == 0) return;

    var records = try recent(io, allocator, environ, 500);
    defer freeRecords(allocator, records);
    if (records.len == 500) {
        allocator.free(records[0].text);
        records = records[1..];
    }

    const path = try historyPath(io, allocator, environ);
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    for (records) |record| try writeRecord(io, file, record.created_at, record.text);
    const now = std.Io.Clock.real.now(io);
    try writeRecord(io, file, @intCast(@divTrunc(now.nanoseconds, 1_000_000_000)), text);
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
    while (offset < content.len) {
        if (content.len - offset < 12) break;
        const created_at: i64 = @intCast(std.mem.bytesToValue(u64, content[offset..][0..8]));
        const length: usize = std.mem.bytesToValue(u32, content[offset + 8 ..][0..4]);
        offset += 12;
        if (length > content.len - offset) break;
        const text = try allocator.dupe(u8, content[offset..][0..length]);
        errdefer allocator.free(text);
        try records.append(allocator, .{ .created_at = created_at, .text = text });
        offset += length;
    }

    if (records.items.len > limit) {
        const drop = records.items.len - limit;
        for (records.items[0..drop]) |record| allocator.free(record.text);
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
}

pub fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {
    if (records.len == 0) return;
    for (records) |record| allocator.free(record.text);
    allocator.free(records);
}

fn writeRecord(io: std.Io, file: std.Io.File, created_at: i64, text: []const u8) !void {
    var header: [12]u8 = undefined;
    @memcpy(header[0..8], std.mem.asBytes(&@as(u64, @intCast(created_at))));
    @memcpy(header[8..12], std.mem.asBytes(&@as(u32, @intCast(text.len))));
    try file.writeStreamingAll(io, &header);
    try file.writeStreamingAll(io, text);
}
