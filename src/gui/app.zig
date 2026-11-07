//! Unified GUI entry point: `--daemon` runs the platform daemon, otherwise
//! the shared nanoui desktop UI.

const std = @import("std");
const builtin = @import("builtin");

const daemon = @import("desktop/daemon_linux.zig");

pub fn main(init: std.process.Init) !void {
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
