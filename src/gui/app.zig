//! Unified GUI entry point. Platform frontends live under `platforms/`.

const std = @import("std");
const builtin = @import("builtin");

const platform = switch (builtin.os.tag) {
    .linux => @import("platforms/linux.zig"),
    .macos => @import("platforms/macos.zig"),
    .windows => @import("platforms/windows.zig"),
    else => @compileError("kocr-gui supports Linux, Windows, and macOS only"),
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--daemon")) return platform.runDaemon(init);
    }
    try platform.run(init);
}
