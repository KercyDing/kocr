//! Platform daemon entry: global shortcuts run capture, OCR, and history.

const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    .macos => @import("unsupported.zig"),
    else => @compileError("kocr daemon supports Linux, Windows, and macOS only"),
};

pub const initProcess = platform.initProcess;
pub const run = platform.run;
pub const isRunning = platform.isRunning;
pub const ensureRunning = platform.ensureRunning;
pub const stop = platform.stop;
