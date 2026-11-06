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

pub fn toggleDaemon(state: *State) void {
    if (state.daemon_running) {
        daemon.stop(state.io, state.allocator, state.environ) catch |err| {
            var buffer: [256]u8 = undefined;
            state.setMainStatus(std.fmt.bufPrint(&buffer, "Daemon stop failed: {s}", .{@errorName(err)}) catch "Daemon stop failed");
            return;
        };
        state.setMainStatus("Daemon stopped");
    } else {
        daemon.ensureRunning(state.io, state.allocator, state.environ) catch |err| switch (err) {
            error.AlreadyRunning => {
                state.setMainStatus("Daemon already running");
                _ = updateDaemon(state);
                return;
            },
            else => {
                var buffer: [256]u8 = undefined;
                state.setMainStatus(std.fmt.bufPrint(&buffer, "Daemon start failed: {s}", .{@errorName(err)}) catch "Daemon start failed");
                return;
            },
        };
        state.setMainStatus("Daemon started");
    }
    _ = updateDaemon(state);
}
