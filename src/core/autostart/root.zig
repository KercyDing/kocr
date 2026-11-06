//! Login autostart, per platform.

const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("kocr supports Linux, Windows, and macOS only"),
};

pub const enabled = platform.enabled;
pub const set = platform.set;
