//! Desktop GUI entry: the agent app, its windows, and its timers.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");
const nui = @import("nanoui");

const daemon = @import("daemon_linux.zig");
const history = @import("history.zig");
const jobs = @import("jobs.zig");
const model = @import("model.zig");
const state_mod = @import("state.zig");
const tray = @import("../tray/root.zig");
const windows = @import("windows.zig");

const State = state_mod.State;
const macos = builtin.os.tag == .macos;
const win = builtin.os.tag == .windows;
const agent = macos or win;

fn refreshTimer(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    var changed = history.pollHistory(state);
    const changed_model = model.updateModelStatus(state);
    if (changed_model) changed = true;
    if (changed) state.redraw();
    nui.App.after(1000, state, refreshTimer);
}

fn onReopen(context: ?*anyopaque) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    windows.showMain(state);
}

fn hotkey(context: *anyopaque, action: core.Action) !bool {
    const state: *State = @ptrCast(@alignCast(context));
    jobs.startCapture(state, switch (action) {
        .copy => .copy_image,
        .save => .save_image,
        .ocr => .extract,
        .oneline => .extract_oneline,
    });
    return true;
}

fn trayTimer(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    tray.pump();
    if (tray.takeShowRequest()) windows.showMain(state);
    nui.App.after(50, state, trayTimer);
}

pub fn run(init: std.process.Init) !void {
    if (!tray.claim()) return;
    var state = try State.init(init);
    defer state.deinit();

    const app = try nui.App.create(init, .{
        .name = core.dirs.name,
        .quit_on_last_window_closed = !agent,
        .ctx = &state,
        .on_reopen = if (agent) onReopen else null,
    });
    defer app.destroy();
    state.app = app;

    if (core.config.load(init.gpa, init.io, init.environ_map)) |value| {
        var parsed = value;
        state.show_tray = parsed.value.ui.tray;
        state.theme = parsed.value.ui.theme;
        parsed.deinit();
    } else |_| {}

    if (agent) {
        if (macos) {
            // A menu bar app: no Dock icon ever, windows or not.
            _ = nui.objc.msg(nui.objc.BOOL, app.nsapp, "setActivationPolicy:", .{@as(nui.objc.NSInteger, 1)});
        }
        tray.sync(&state);
        if (win) nui.App.after(50, &state, trayTimer);
        core.startHotkeys(init.gpa, init.io, init.environ_map, &state, hotkey) catch |err| {
            std.debug.print("kocr: shortcuts unavailable: {s}\n", .{@errorName(err)});
        };
    } else {
        // No tray and no toggle: the daemon that serves the shortcuts comes up
        // with the window, quietly.
        daemon.startInBackground(&state);
        windows.showMain(&state);
    }

    model.loadSelection(&state);
    _ = model.updateModelStatus(&state);
    history.loadHistory(&state);
    nui.App.after(1000, &state, refreshTimer);

    try app.run();
}
