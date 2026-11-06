//! Desktop GUI entry: windows, timers, and startup.

const std = @import("std");

const nui = @import("nanoui");

const daemon = @import("daemon.zig");
const history = @import("history.zig");
const main = @import("main.zig");
const model = @import("model.zig");
const state_mod = @import("state.zig");

const State = state_mod.State;

fn refreshTimer(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    var changed = history.pollHistory(state);
    if (daemon.updateDaemon(state)) changed = true;
    const changed_model = model.updateModelStatus(state);
    if (changed_model) changed = true;
    if (changed) state.redraw();
    nui.App.after(1000, state, refreshTimer);
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(init: std.process.Init) !void {
    var state = try State.init(init);
    defer state.deinit();

    const app = try nui.App.create(init, .{ .name = "kocr" });
    defer app.destroy();
    state.app = app;

    const window = try app.newWindow(.{
        .title = "kocr gui",
        .width = 820,
        .height = 620,
        .min_width = 640,
        .min_height = 520,
        .content = .{ .view = .init(&state, main.view) },
    });
    state.main_window = window;

    model.loadSelection(&state);
    _ = model.updateModelStatus(&state);
    _ = daemon.updateDaemon(&state);
    history.loadHistory(&state);
    nui.App.after(1000, &state, refreshTimer);

    try app.run();
}
