//! The optional tray icon, per platform.

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

/// Whether this process is the only instance. Windows broadcasts a request
/// for the existing copy to show its window.
pub fn claim() bool {
    return platform.claim();
}

pub fn pump() void {
    platform.pump();
}

pub fn takeShowRequest() bool {
    return platform.takeShowRequest();
}
