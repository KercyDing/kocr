//! Clipboard text and images, per platform.

const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("kocr supports Linux, Windows, and macOS only"),
};

pub const copyText = platform.copyText;
pub const copyImage = platform.copyImage;
