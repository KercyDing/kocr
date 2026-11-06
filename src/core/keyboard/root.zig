//! Global shortcuts, per platform.

const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("kocr supports Linux, Windows, and macOS only"),
};

pub const KeyboardError = platform.KeyboardError;
pub const listen = platform.listen;
pub const listenConfigured = platform.listenConfigured;
