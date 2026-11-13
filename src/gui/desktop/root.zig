//! Desktop GUI entry: the agent app, its windows, and its timers.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");
const nui = @import("nanoui");

const history = @import("history.zig");
const jobs = @import("jobs.zig");
const model = @import("model.zig");
const state_mod = @import("state.zig");
const tray = @import("../tray/root.zig");
const windows = @import("windows.zig");

const State = state_mod.State;
const lin = builtin.os.tag == .linux;
const macos = builtin.os.tag == .macos;
const win = builtin.os.tag == .windows;

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
    if (lin) {
        // The Linux listener has a thread of its own: captures run on the loop.
        const press = std.heap.c_allocator.create(Press) catch return false;
        press.* = .{ .state = state, .action = action };
        if (!nui.App.onMain(press, runPress)) {
            std.heap.c_allocator.destroy(press);
            return false;
        }
        return true;
    }
    startAction(state, action);
    return true;
}

const Press = struct { state: *State, action: core.Action };

fn runPress(context: ?*anyopaque) callconv(.c) void {
    const press: *Press = @ptrCast(@alignCast(context orelse return));
    defer std.heap.c_allocator.destroy(press);
    startAction(press.state, press.action);
}

fn startAction(state: *State, action: core.Action) void {
    jobs.startCapture(state, switch (action) {
        .copy => .copy_image,
        .save => .save_image,
        .ocr => .extract,
        .oneline => .extract_oneline,
    });
}

fn trayTimer(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    tray.pump();
    if (tray.takeShowRequest()) windows.showMain(state);
    nui.App.after(50, state, trayTimer);
}

pub fn run(init: std.process.Init) !void {
    if (!tray.claim(init.io)) return;
    var state = try State.init(init);
    defer state.deinit();

    // The tray decides whether closing the window ends kocr.
    if (core.config.load(init.gpa, init.io, init.environ_map)) |value| {
        var parsed = value;
        state.show_tray = parsed.value.ui.tray;
        state.theme = parsed.value.ui.theme;
        parsed.deinit();
    } else |_| {}

    const app = try nui.App.create(init, .{
        .name = core.dirs.name,
        // The tray is the app's handle once its window closes, on every platform.
        .quit_on_last_window_closed = false,
        .ctx = &state,
        .on_reopen = if (macos) onReopen else null,
    });
    defer app.destroy();
    state.app = app;

    if (macos) {
        // A menu bar app: no Dock icon ever, windows or not.
        _ = nui.objc.msg(nui.objc.BOOL, app.nsapp, "setActivationPolicy:", .{@as(nui.objc.NSInteger, 1)});
    }
    tray.sync(&state);
    if (win) nui.App.after(50, &state, trayTimer);
    core.startHotkeys(init.gpa, init.io, init.environ_map, &state, hotkey) catch |err| {
        std.debug.print("kocr: shortcuts unavailable: {s}\n", .{@errorName(err)});
    };

    model.loadSelection(&state);
    _ = model.updateModelStatus(&state);
    history.loadHistory(&state);
    nui.App.after(1000, &state, refreshTimer);

    try app.run();
}
