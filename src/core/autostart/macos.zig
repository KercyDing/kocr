const std = @import("std");

pub fn enabled(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !bool {
    return false;
}

pub fn set(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map, _: bool, _: []const u8) !void {
    return error.UnsupportedPlatform;
}
