//! Where kocr keeps its folders, per platform:
//! `<config>/Kocr` and `<data>/Kocr`.

const std = @import("std");
const builtin = @import("builtin");

/// The folder under both roots.
pub const name = "Kocr";

pub fn configRoot(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => (try env(allocator, environ, "APPDATA")) orelse error.DirUnavailable,
        .macos => try home(allocator, environ, &.{ "Library", "Preferences" }),
        else => try xdg(allocator, environ, "XDG_CONFIG_HOME", ".config"),
    };
}

pub fn dataRoot(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => (try env(allocator, environ, "LOCALAPPDATA")) orelse error.DirUnavailable,
        .macos => try home(allocator, environ, &.{ "Library", "Application Support" }),
        else => try xdg(allocator, environ, "XDG_DATA_HOME", ".local/share"),
    };
}

/// `environ[key]`, empty read as unset; owned by `allocator`.
fn env(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, key: []const u8) !?[]u8 {
    const value = environ.get(key) orelse return null;
    if (value.len == 0) return null;
    return try allocator.dupe(u8, value);
}

/// `$HOME/<parts>`.
fn home(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, parts: []const []const u8) ![]u8 {
    const dir = (try env(allocator, environ, "HOME")) orelse return error.DirUnavailable;
    defer allocator.free(dir);
    const joined = try allocator.alloc([]const u8, parts.len + 1);
    defer allocator.free(joined);
    joined[0] = dir;
    @memcpy(joined[1..], parts);
    return std.Io.Dir.path.join(allocator, joined);
}

/// `$<key>`, else `$HOME/<fallback>`. A relative `key` is ignored, as the
/// XDG base directory spec asks.
fn xdg(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    key: []const u8,
    fallback: []const u8,
) ![]u8 {
    if (environ.get(key)) |value| {
        if (value.len != 0 and std.Io.Dir.path.isAbsolute(value)) return allocator.dupe(u8, value);
    }
    return home(allocator, environ, &.{fallback});
}

test "roots read the environment" {
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();

    switch (builtin.os.tag) {
        .windows => {
            try environ.put("APPDATA", "C:\\Users\\u\\AppData\\Roaming");
            try environ.put("LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local");
        },
        .macos => {
            try environ.put("HOME", "/Users/u");
        },
        else => {
            try environ.put("HOME", "/home/u");
            try environ.put("XDG_CONFIG_HOME", "/cfg");
            try environ.put("XDG_DATA_HOME", "/data");
        },
    }

    const config = try configRoot(allocator, &environ);
    defer allocator.free(config);
    const data = try dataRoot(allocator, &environ);
    defer allocator.free(data);

    switch (builtin.os.tag) {
        .windows => {
            try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Roaming", config);
            try std.testing.expectEqualStrings("C:\\Users\\u\\AppData\\Local", data);
        },
        .macos => {
            try std.testing.expectEqualStrings("/Users/u/Library/Preferences", config);
            try std.testing.expectEqualStrings("/Users/u/Library/Application Support", data);
        },
        else => {
            try std.testing.expectEqualStrings("/cfg", config);
            try std.testing.expectEqualStrings("/data", data);
        },
    }
}

test "relative XDG paths fall back to home" {
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) return;
    const allocator = std.testing.allocator;
    var environ = std.process.Environ.Map.init(allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/u");
    try environ.put("XDG_CONFIG_HOME", "relative");

    const config = try configRoot(allocator, &environ);
    defer allocator.free(config);
    try std.testing.expectEqualStrings("/home/u/.config", config);
}
