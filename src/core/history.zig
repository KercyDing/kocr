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
    limit: usize = kept,
    before_id: ?i64 = null,
    kind: ?Kind = null,
    search: ?[]const u8 = null,
};

/// A stamp that changes with every write, this process's or another's.
pub const Revision = i64;

/// Rows the history keeps; older ones are pruned with their pictures.
pub const kept: usize = 200;

pub fn historyPath(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const root = try model.paths.dataRoot(allocator, environ);
    defer allocator.free(root);
    return std.Io.Dir.path.join(allocator, &.{ root, "history.sqlite3" });
}

pub fn imagesDir(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const root = try model.paths.dataRoot(allocator, environ);
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
    return writes(conn);
}

/// The database header's `user_version`, which every write bumps: one read
/// whatever the history holds, and it sees deletes too, not just new rows.
fn writes(conn: zqlite.Conn) !Revision {
    const row = try conn.row("PRAGMA user_version", .{}) orelse return 0;
    defer row.deinit();
    return row.int(0);
}

/// Marks the history as written, so `revision` reports the change.
fn bump(conn: zqlite.Conn) !void {
    var buffer: [48]u8 = undefined;
    const sql = try std.fmt.bufPrint(&buffer, "PRAGMA user_version = {d}", .{try writes(conn) + 1});
    try conn.exec(sql, .{});
}

/// Drops all but the newest `kept` rows, and the pictures of the ones dropped.
fn prune(conn: zqlite.Conn, io: std.Io, allocator: std.mem.Allocator) !void {
    const oldest_kept = blk: {
        const row = try conn.row("SELECT id FROM captures ORDER BY id DESC LIMIT 1 OFFSET ?1", .{@as(i64, kept)}) orelse return;
        defer row.deinit();
        break :blk row.int(0);
    };
    var pictures: std.ArrayList([]u8) = .empty;
    defer {
        for (pictures.items) |path| allocator.free(path);
        pictures.deinit(allocator);
    }
    var rows = try conn.rows("SELECT image_path FROM captures WHERE id <= ?1 AND image_path IS NOT NULL", .{oldest_kept});
    defer rows.deinit();
    while (rows.next()) |row| {
        const path = row.nullableText(0) orelse continue;
        try pictures.append(allocator, try allocator.dupe(u8, path));
    }
    if (rows.err) |err| return err;
    try conn.exec("DELETE FROM captures WHERE id <= ?1", .{oldest_kept});
    for (pictures.items) |path| std.Io.Dir.cwd().deleteFile(io, path) catch {};
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
    try prune(conn, io, allocator);
    try bump(conn);
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

    const directory = try imagesDir(allocator, environ);
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
    try prune(conn, io, allocator);
    try bump(conn);
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
    try bump(conn);
}

pub fn clear(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) !void {
    var conn = try open(io, allocator, environ);
    defer conn.close();
    try conn.execNoArgs("DELETE FROM captures");
    try bump(conn);
    const directory = try imagesDir(allocator, environ);
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
    const path = try historyPath(allocator, environ);
    defer allocator.free(path);
    try std.Io.Dir.cwd().createDirPath(io, std.Io.Dir.path.dirname(path) orelse ".");
    const path_z = try allocator.dupeSentinel(u8, path, 0);
    defer allocator.free(path_z);

    // Every call opens the file, a poll once a second; the schema and the
    // journal mode only ever have to be made once, for a new database.
    const known = blk: {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        file.close(io);
        break :blk true;
    };

    var conn = try zqlite.open(path_z, zqlite.OpenFlags.Create | zqlite.OpenFlags.EXResCode);
    errdefer conn.close();
    try conn.busyTimeout(2000);
    if (!known) try migrate(conn);
    return conn;
}

fn migrate(conn: zqlite.Conn) !void {
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
}

fn timestamp(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    return @intCast(@divTrunc(now.nanoseconds, 1_000_000_000));
}

test "keeps the newest rows and reports every write" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("KOCR_DATA_HOME", root);

    const start = try revision(io, allocator, &env);
    var index: usize = 0;
    while (index < kept + 5) : (index += 1) try appendText(io, allocator, &env, "text");

    const records = try recent(io, allocator, &env, kept + 10);
    defer freeRecords(allocator, records);
    try std.testing.expectEqual(kept, records.len);

    const appended = try revision(io, allocator, &env);
    try std.testing.expect(appended > start);

    // An old row going away moves the stamp too: a count of rows would not.
    try delete(io, allocator, &env, records[kept - 1].id);
    try std.testing.expect((try revision(io, allocator, &env)) > appended);
}

test "queries, deletes, and clears history" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];

    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("KOCR_DATA_HOME", root);

    try appendText(io, allocator, &env, "first text");
    try appendText(io, allocator, &env, "second text");
    const source = try std.Io.Dir.path.join(allocator, &.{ root, "capture.png" });
    defer allocator.free(source);
    // Only the copy is under test, so the bytes need not be a decodable image.
    try tmp.dir.writeFile(io, .{ .sub_path = "capture.png", .data = "\x89PNG\r\n\x1a\n" });
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
