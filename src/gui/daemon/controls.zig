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
        const started = daemon.ensureRunning(state.io, state.allocator, state.environ) catch |err| {
            var buffer: [256]u8 = undefined;
            state.setMainStatus(std.fmt.bufPrint(&buffer, "Daemon start failed: {s}", .{@errorName(err)}) catch "Daemon start failed");
            return;
        };
        state.setMainStatus(if (started) "Daemon started" else "Daemon already running");
    }
    _ = updateDaemon(state);
}
