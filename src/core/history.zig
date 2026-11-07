//! SQLite-backed text and image history.
//! Schema and image directory match kocr-rs for compatibility.

const std = @import("std");

const model = @import("model/model.zig");
const timestamp_name = @import("timestamp.zig");
const zqlite = @import("zqlite");

pub const Kind = enum {
    text,
    image,
};

pub const Content = union(Kind) {
    text: []u8,
    image: []u8,
};

pub const Record = struct {
    id: i64,
    created_at: i64,
    content: Content,
};

pub const Query = struct {
    limit: usize = 200,
    before_id: ?i64 = null,
    kind: ?Kind = null,
    search: ?[]const u8 = null,
};

pub const Revision = struct {
    count: i64,
    max_id: i64,
};

pub fn historyPath(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const root = try model.paths.dataRoot(io, allocator, environ);
    defer allocator.free(root);
    return std.Io.Dir.path.join(allocator, &.{ root, "history.sqlite3" });
}

pub fn imagesDir(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const root = try model.paths.dataRoot(io, allocator, environ);
    defer allocator.free(root);
    return std.Io.Dir.path.join(allocator, &.{ root, "history" });
}

pub fn revision(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !Revision {
    var conn = try open(io, allocator, environ);
    defer conn.close();
    if (try conn.row("SELECT COUNT(*), COALESCE(MAX(id), 0) FROM captures", .{})) |row| {
        defer row.deinit();
        return .{ .count = row.int(0), .max_id = row.int(1) };
    }
    return .{ .count = 0, .max_id = 0 };
}

pub fn appendText(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    text: []const u8,
) !void {
    if (text.len == 0) return;
    var conn = try open(io, allocator, environ);
    defer conn.close();
    try conn.exec(
        "INSERT INTO captures (created_at, kind, text) VALUES (?1, 'text', ?2)",
        .{ timestamp(io), text },
    );
}

/// Copies an absolute source path into the history image directory.
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

    var name_buffer: [80]u8 = undefined;
    const name = timestamp_name.fileName(io, &name_buffer, "kocr", "png");
    const destination = try std.Io.Dir.path.join(allocator, &.{ directory, name });
    defer allocator.free(destination);
    try std.Io.Dir.copyFileAbsolute(source_path, destination, io, .{});
    errdefer std.Io.Dir.cwd().deleteFile(io, destination) catch {};

    var conn = try open(io, allocator, environ);
    defer conn.close();
    try conn.exec(
        "INSERT INTO captures (created_at, kind, image_path) VALUES (?1, 'image', ?2)",
        .{ timestamp(io), destination },
    );
}

pub fn recent(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    limit: usize,
) ![]Record {
    return query(io, allocator, environ, .{ .limit = limit });
}

pub fn query(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    options: Query,
) ![]Record {
    var search_pattern: ?[]u8 = null;
    defer if (search_pattern) |pattern| allocator.free(pattern);
    if (options.search) |search| {
        if (search.len != 0) {
            search_pattern = try std.fmt.allocPrint(allocator, "%{s}%", .{search});
        }
    }
    const kind_name: ?[]const u8 = if (options.kind) |kind| @tagName(kind) else null;

    var conn = try open(io, allocator, environ);
    defer conn.close();
    var rows = try conn.rows(
        \\SELECT id, created_at, kind, text, image_path
        \\FROM captures
        \\WHERE (:before IS NULL OR id < :before)
        \\  AND (:kind IS NULL OR kind = :kind)
        \\  AND (:search IS NULL OR text LIKE :search)
        \\ORDER BY id DESC
        \\LIMIT :limit
    , .{
        .before = options.before_id,
        .kind = kind_name,
        .search = search_pattern,
        .limit = @as(i64, @intCast(options.limit)),
    });
    defer rows.deinit();

    var records: std.ArrayList(Record) = .empty;
    errdefer freeRecords(allocator, records.items);
    while (rows.next()) |row| {
        const kind = std.meta.stringToEnum(Kind, row.text(2)) orelse continue;
        const text = row.nullableText(3);
        const image = row.nullableText(4);
        const content: Content = switch (kind) {
            .text => .{ .text = try allocator.dupe(u8, text orelse "") },
            .image => .{ .image = try allocator.dupe(u8, image orelse "") },
        };
        errdefer switch (content) {
            .text => |value| allocator.free(value),
            .image => |value| allocator.free(value),
        };
        try records.append(allocator, .{
            .id = row.int(0),
            .created_at = row.int(1),
            .content = content,
        });
    }
    if (rows.err) |err| return err;
    return records.toOwnedSlice(allocator);
}

pub fn delete(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    id: i64,
) !void {
    var conn = try open(io, allocator, environ);
    defer conn.close();
    if (try conn.row("SELECT image_path FROM captures WHERE id = ?1", .{id})) |row| {
        defer row.deinit();
        if (row.nullableText(0)) |path| {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
        }
    }
    try conn.exec("DELETE FROM captures WHERE id = ?1", .{id});
}

pub fn clear(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    var conn = try open(io, allocator, environ);
    defer conn.close();
    try conn.execNoArgs("DELETE FROM captures");
    const directory = try imagesDir(io, allocator, environ);
    defer allocator.free(directory);
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
}

pub fn freeRecords(allocator: std.mem.Allocator, records: []Record) void {
    if (records.len == 0) return;
    for (records) |record| switch (record.content) {
        .text => |text| allocator.free(text),
        .image => |image| allocator.free(image),
    };
    allocator.free(records);
}

fn open(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !zqlite.Conn {
    const path = try historyPath(io, allocator, environ);
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    var conn = try zqlite.open(path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    errdefer conn.close();
    try conn.busyTimeout(2000);
    try conn.execNoArgs(
        \\PRAGMA journal_mode = WAL;
        \\CREATE TABLE IF NOT EXISTS captures (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  created_at INTEGER NOT NULL,
        \\  kind TEXT NOT NULL,
        \\  text TEXT,
        \\  image_path TEXT
        \\);
        \\CREATE INDEX IF NOT EXISTS captures_kind_id ON captures(kind, id DESC);
    );
    return conn;
}

fn timestamp(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    return @intCast(@divTrunc(now.nanoseconds, 1_000_000_000));
}

test "queries, deletes, and clears history" {
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
    // macOS resolves data folders from HOME; XDG_DATA_HOME covers Linux.
    try env.put("HOME", root);
    try env.put("XDG_DATA_HOME", root);

    try appendText(io, allocator, &env, "first text");
    try appendText(io, allocator, &env, "second text");
    const source = try std.Io.Dir.path.join(allocator, &.{ root, "capture.png" });
    defer allocator.free(source);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source, .data = "\x89PNG\r\n\x1a\n" });
    try appendImage(io, allocator, &env, source);

    {
        const records = try query(io, allocator, &env, .{ .limit = 10 });
        defer freeRecords(allocator, records);
        try std.testing.expectEqual(@as(usize, 3), records.len);
        try std.testing.expectEqual(Kind.image, std.meta.activeTag(records[0].content));
    }

    {
        const records = try query(io, allocator, &env, .{ .limit = 10, .kind = .text, .search = "second" });
        defer freeRecords(allocator, records);
        try std.testing.expectEqual(@as(usize, 1), records.len);
    }

    {
        const records = try query(io, allocator, &env, .{ .limit = 1 });
        defer freeRecords(allocator, records);
        try std.testing.expectEqual(@as(usize, 1), records.len);
        try delete(io, allocator, &env, records[0].id);
    }

    {
        const records = try recent(io, allocator, &env, 10);
        defer freeRecords(allocator, records);
        try std.testing.expectEqual(@as(usize, 2), records.len);
    }

    try clear(io, allocator, &env);
    const records = try recent(io, allocator, &env, 10);
    defer freeRecords(allocator, records);
    try std.testing.expectEqual(@as(usize, 0), records.len);
}
