//! macOS daemon: the shared desktop loop; process control is stubbed.

const std = @import("std");

const native = @import("native.zig");

pub const run = native.serve;

pub fn isRunning(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !bool {
    return false;
}

pub fn ensureRunning(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) anyerror!void {
    return error.UnsupportedPlatform;
}

pub fn stop(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !void {
    return error.UnsupportedPlatform;
}

pub fn initProcess() void {}
