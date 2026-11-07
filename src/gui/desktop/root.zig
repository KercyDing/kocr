//! Desktop GUI entry: the agent app, its windows, and its timers.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");
const nui = @import("nanoui");

const daemon = @import("../daemon/controls.zig");
const history = @import("history.zig");
const jobs = @import("jobs.zig");
const model = @import("model.zig");
const state_mod = @import("state.zig");
const theme = @import("theme.zig");
const tray = @import("tray.zig");
const windows = @import("windows.zig");

const State = state_mod.State;
const macos = builtin.os.tag == .macos;

fn refreshTimer(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    theme.sync(state);
    const dark = nui.isDark();
    if (state.title_bar_dark != dark) {
        state.title_bar_dark = dark;
        if (state.main_window) |window| @import("titlebar.zig").apply(window);
        if (state.settings_window) |window| @import("titlebar.zig").apply(window);
    }
    var changed = history.pollHistory(state);
    if (!macos and daemon.updateDaemon(state)) changed = true;
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

pub fn run(init: std.process.Init) !void {
    var state = try State.init(init);
    defer state.deinit();

    const app = try nui.App.create(init, .{
        .name = "kocr",
        .quit_on_last_window_closed = !macos,
        .ctx = &state,
        .on_reopen = if (macos) onReopen else null,
    });
    defer app.destroy();
    state.app = app;

    if (macos) {
        // A menu bar app: no Dock icon ever, windows or not.
        _ = nui.objc.msg(nui.objc.BOOL, app.nsapp, "setActivationPolicy:", .{@as(nui.objc.NSInteger, 1)});
        if (core.config.load(init.gpa, init.io, init.environ_map)) |value| {
            var parsed = value;
            state.show_tray = parsed.value.ui.tray;
            parsed.deinit();
        } else |_| {}
        tray.sync(&state);
        core.startHotkeys(init.gpa, init.io, init.environ_map, &state, hotkey) catch |err| {
            std.debug.print("kocr: shortcuts unavailable: {s}\n", .{@errorName(err)});
        };
    } else {
        windows.showMain(&state);
        _ = daemon.updateDaemon(&state);
    }

    model.loadSelection(&state);
    _ = model.updateModelStatus(&state);
    history.loadHistory(&state);
    nui.App.after(1000, &state, refreshTimer);

    try app.run();
}
