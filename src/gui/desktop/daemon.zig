//! Daemon controls shown in the main window.

const std = @import("std");

const core = @import("core");

const state_mod = @import("state.zig");

const State = state_mod.State;

pub fn updateDaemon(state: *State) bool {
    const running = core.daemon_process.isRunning(state.io, state.allocator, state.environ) catch false;
    if (running == state.daemon_running) return false;
    state.daemon_running = running;
    return true;
}

pub fn toggleDaemon(state: *State) void {
    if (state.daemon_running) {
        core.daemon_process.stop(state.io, state.allocator, state.environ) catch |err| {
            var buffer: [256]u8 = undefined;
            state.setMainStatus(std.fmt.bufPrint(&buffer, "Daemon stop failed: {s}", .{@errorName(err)}) catch "Daemon stop failed");
            return;
        };
        state.setMainStatus("Daemon stopped");
    } else {
        const started = core.daemon_process.ensureRunning(state.io, state.allocator, state.environ) catch |err| {
            var buffer: [256]u8 = undefined;
            state.setMainStatus(std.fmt.bufPrint(&buffer, "Daemon start failed: {s}", .{@errorName(err)}) catch "Daemon start failed");
            return;
        };
        state.setMainStatus(if (started) "Daemon started" else "Daemon already running");
    }
    _ = updateDaemon(state);
}
