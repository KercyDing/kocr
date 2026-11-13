//! The GUI entry point: one process with its tray and its shortcuts.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");

pub fn main(init: std.process.Init) !void {
    scanEnvironment(init);
    try @import("desktop/root.zig").run(init);
}

/// std reads the startup environ lazily: once for stderr, once for PATH on the
/// first `spawn`. GTK unsets `DESKTOP_STARTUP_ID` and `XDG_ACTIVATION_TOKEN`
/// before either, shortening that array under the cached slice, so both reads
/// hit a null entry: https://codeberg.org/ziglang/zig/issues/35512 (fix:
/// https://codeberg.org/ziglang/zig/pulls/36817). Scan them while it is whole.
fn scanEnvironment(init: std.process.Init) void {
    var buffer: [1]u8 = undefined;
    _ = std.debug.lockStderr(&buffer);
    std.debug.unlockStderr();
    // GTK only runs on Linux; `true` comes with coreutils there.
    if (builtin.os.tag != .linux) return;
    var child = core.proc.spawn(init.io, init.environ_map, .{
        .argv = &.{"true"},
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(init.io) catch {};
}
