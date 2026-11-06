const std = @import("std");

pub const Capture = @import("screenshot.zig").Capture;
pub const screenshot = @import("screenshot.zig");
pub const keyboard = @import("keyboard.zig");
pub const autostart = struct {
    pub fn enabled(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !bool {
        return false;
    }
    pub fn set(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map, _: bool, _: []const u8) !void {
        return error.UnsupportedPlatform;
    }
};
pub const clipboard = struct {
    pub fn copyText(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, _: []const u8) !void {
        return error.UnsupportedPlatform;
    }
    pub fn copyImage(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, _: []const u8) !void {
        return error.UnsupportedPlatform;
    }
};
pub const daemon_process = struct {
    pub fn isRunning(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !bool {
        return false;
    }
    pub fn ensureRunning(_: std.Io, _: std.mem.Allocator, _: *const std.process.Environ.Map) !bool {
        return error.UnsupportedPlatform;
    }
};
