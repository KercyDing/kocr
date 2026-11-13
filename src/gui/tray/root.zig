//! The optional tray icon, per platform.

const std = @import("std");
const builtin = @import("builtin");

const state_mod = @import("../desktop/state.zig");

const platform = switch (builtin.os.tag) {
    .macos => @import("macos.zig"),
    .windows => @import("windows.zig"),
    .linux => @import("linux.zig"),
    else => @compileError("kocr supports Linux, Windows, and macOS only"),
};

pub fn sync(state: *state_mod.State) void {
    platform.sync(state);
}

/// Whether this process is the only instance. A second launch asks the
/// existing copy to show its window: through a named event on Windows, a
/// unix socket on Linux.
pub fn claim(io: std.Io) bool {
    return platform.claim(io);
}

pub fn pump() void {
    platform.pump();
}

pub fn takeShowRequest() bool {
    return platform.takeShowRequest();
}
