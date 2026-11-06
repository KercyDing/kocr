//! Platform layer selected at compile time.

const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .linux => @import("linux/root.zig"),
    .windows => @import("windows/root.zig"),
    .macos => @import("macos/root.zig"),
    else => @compileError("kocr supports Linux, Windows, and macOS only"),
};

pub const Capture = platform.Capture;
pub const screenshot = platform.screenshot;
pub const keyboard = platform.keyboard;
pub const autostart = platform.autostart;
pub const clipboard = platform.clipboard;
pub const daemon_process = platform.daemon_process;
