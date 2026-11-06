//! Platform-independent capture, shortcut, and daemon entry points.
//! Platform-specific rules live below `<platform>/` and are selected by the build.

const std = @import("std");

pub const daemon = @import("daemon.zig");

const platform = @import("core_platform");
pub const types = @import("core_types");

pub const Action = types.Action;
pub const Binding = types.Binding;

pub const Capture = platform.Capture;
pub const Screenshot = platform.screenshot;
pub const Keyboard = platform.keyboard;
pub const autostart = platform.autostart;
pub const clipboard = platform.clipboard;
pub const daemon_process = platform.daemon_process;

pub const CaptureError = Screenshot.CaptureError;
pub const KeyboardError = Keyboard.KeyboardError;

pub fn captureRegion(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_path: []const u8,
) !Capture {
    return Screenshot.captureRegion(allocator, io, output_path);
}

/// Blocks while the platform shortcut listener is active.
/// The handler returns false to stop listening.
pub fn listen(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    bindings: []const Binding,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    return Keyboard.listen(allocator, io, environ, bindings, context, handler);
}

pub fn listenConfigured(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    return Keyboard.listenConfigured(allocator, io, environ, context, handler);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(daemon);
    std.testing.refAllDecls(Keyboard);
    std.testing.refAllDecls(Screenshot);
}
