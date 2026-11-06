//! Platform-independent capture, shortcut, and daemon entry points.
//! Platform implementations live under `<capability>/<os>.zig`.

const std = @import("std");

const keyboard = @import("keyboard/root.zig");
const screenshot = @import("screenshot/root.zig");

const library = @import("lib.zig");

pub const config = @import("config.zig");
pub const types = @import("types.zig");

pub const model = library.model;
pub const paths = library.paths;
pub const downloader = library.downloader;
pub const history = library.history;
pub const Image = library.Image;
pub const Line = library.Line;
pub const TextBox = library.TextBox;
pub const Options = library.Options;
pub const recognizeFile = library.recognizeFile;
pub const recognizeImage = library.recognizeImage;
pub const detectFile = library.detectFile;
pub const recognizeLine = library.recognizeLine;
pub const freeLines = library.freeLines;
pub const linesToText = library.linesToText;

pub const Action = types.Action;
pub const Binding = types.Binding;

pub const Capture = screenshot.Capture;
pub const Screenshot = screenshot;
pub const Keyboard = keyboard;
pub const autostart = @import("autostart/root.zig");
pub const clipboard = @import("clipboard/root.zig");

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
    std.testing.refAllDecls(Keyboard);
    std.testing.refAllDecls(Screenshot);
}
