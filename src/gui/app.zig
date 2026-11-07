//! Unified GUI entry point: `--daemon` runs the platform daemon, otherwise
//! the shared nanoui desktop UI.

const std = @import("std");
const builtin = @import("builtin");

const daemon = @import("desktop/daemon_linux.zig");

pub fn main(init: std.process.Init) !void {
    scanEnvironment();
    daemon.initProcess();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) {
            if (builtin.os.tag == .linux) return daemon.run(init);
            continue;
        }
    }
    try @import("desktop/root.zig").run(init);
}

/// std keeps the startup environ's slice for its first stderr write; GTK
/// unsets variables first, shrinking that array under it and crashing the
/// log. Scan it here, while it is whole.
fn scanEnvironment() void {
    var buffer: [1]u8 = undefined;
    _ = std.debug.lockStderr(&buffer);
    std.debug.unlockStderr();
}
