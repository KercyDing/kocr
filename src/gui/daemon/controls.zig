//! Daemon controls shown in the main window.

const std = @import("std");

const state_mod = @import("../desktop/state.zig");

const daemon = @import("root.zig");

const State = state_mod.State;

pub fn updateDaemon(state: *State) bool {
    const running = daemon.isRunning(state.io, state.allocator, state.environ) catch false;
    if (running == state.daemon_running) return false;
    state.daemon_running = running;
    return true;
}

pub fn applyDaemon(state: *State) void {
    if (state.daemon_running) {
        const started = blk: {
            daemon.ensureRunning(state.io, state.allocator, state.environ) catch |err| switch (err) {
                error.AlreadyRunning => break :blk false,
                else => {
                    var buffer: [256]u8 = undefined;
                    state.setMainStatus(std.fmt.bufPrint(&buffer, "Daemon start failed: {s}", .{@errorName(err)}) catch "Daemon start failed");
                    _ = updateDaemon(state);
                    return;
                },
            };
            break :blk true;
        };
        state.setMainStatus(if (started) "Daemon started" else "Daemon already running");
    } else {
        daemon.stop(state.io, state.allocator, state.environ) catch |err| {
            var buffer: [256]u8 = undefined;
            state.setMainStatus(std.fmt.bufPrint(&buffer, "Daemon stop failed: {s}", .{@errorName(err)}) catch "Daemon stop failed");
            _ = updateDaemon(state);
            return;
        };
        state.setMainStatus("Daemon stopped");
    }
    _ = updateDaemon(state);
}
