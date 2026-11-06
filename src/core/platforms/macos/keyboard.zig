const std = @import("std");

const types = @import("core_types");

pub const KeyboardError = error{UnsupportedPlatform};

pub fn listen(
    _: std.mem.Allocator,
    _: std.Io,
    _: *const std.process.Environ.Map,
    _: []const types.Binding,
    _: *anyopaque,
    _: types.Handler,
) !void {
    return error.UnsupportedPlatform;
}

pub fn listenConfigured(
    _: std.mem.Allocator,
    _: std.Io,
    _: *const std.process.Environ.Map,
    _: *anyopaque,
    _: types.Handler,
) !void {
    return error.UnsupportedPlatform;
}
