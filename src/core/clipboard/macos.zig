const std = @import("std");

pub fn copyText(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn copyImage(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, _: []const u8) !void {
    return error.UnsupportedPlatform;
}
