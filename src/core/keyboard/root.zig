//! Global shortcuts, per platform.

const std = @import("std");
const builtin = @import("builtin");

const types = @import("../types.zig");

const platform = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("kocr supports Linux, Windows, and macOS only"),
};

pub const KeyboardError = platform.KeyboardError;

pub fn listen(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    bindings: []const types.Binding,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    if (builtin.os.tag == .macos) {
        return error.UnsupportedPlatform;
    } else {
        return platform.listen(allocator, io, environ, bindings, context, handler);
    }
}

pub fn listenConfigured(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    if (builtin.os.tag == .macos) {
        return error.UnsupportedPlatform;
    } else {
        return platform.listenConfigured(allocator, io, environ, context, handler);
    }
}

pub fn startConfigured(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    if (builtin.os.tag == .macos or builtin.os.tag == .windows) {
        return platform.startConfigured(allocator, io, environ, context, handler);
    } else {
        return error.UnsupportedPlatform;
    }
}

pub fn reloadConfigured() void {
    if (builtin.os.tag == .macos or builtin.os.tag == .windows) platform.reloadConfigured();
}
