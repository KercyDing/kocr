//! Platform daemon entry: global shortcuts run capture, OCR, and history.

const std = @import("std");
const builtin = @import("builtin");

pub fn run(init: std.process.Init) !void {
    return switch (builtin.os.tag) {
        .linux => @import("linux.zig").run(init),
        .windows => @import("windows.zig").run(init),
        .macos => @import("macos.zig").run(init),
        else => @compileError("kocr daemon supports Linux, Windows, and macOS only"),
    };
}
