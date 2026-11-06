//! Region capture, per platform.

const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("kocr supports Linux, Windows, and macOS only"),
};

pub const Capture = platform.Capture;
pub const CaptureError = platform.CaptureError;
pub const captureRegion = platform.captureRegion;
pub const dependencies = platform.dependencies;
