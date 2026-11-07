//! macOS runs the daemon in the app itself; these entry points are unused.

const std = @import("std");

pub fn initProcess() void {}

pub fn run(_: std.process.Init) !void {
    return error.UnsupportedPlatform;
}

pub fn isRunning(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !bool {
    return false;
}

pub fn ensureRunning(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !void {
    return error.UnsupportedPlatform;
}

pub fn stop(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !void {}
