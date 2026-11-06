//! Unified GUI entry point: `--daemon` runs the platform daemon, otherwise
//! the shared nanoui desktop UI.

const std = @import("std");

const daemon = @import("daemon/root.zig");

pub fn main(init: std.process.Init) !void {
    daemon.initProcess();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) return daemon.run(init);
    }
    try @import("desktop/root.zig").run(init);
}
