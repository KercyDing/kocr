//! Minimal daemon boundary: platform shortcut events drive caller-provided actions.

const std = @import("std");

const platform = @import("core_platform");
const types = @import("core_types");

pub const Handler = types.Handler;

/// Runs until the shortcut backend stops or the handler returns false.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    bindings: []const types.Binding,
    context: *anyopaque,
    handler: Handler,
) !void {
    try platform.keyboard.listen(allocator, io, environ, bindings, context, handler);
}
