//! Main window creation and activation policy.

const std = @import("std");
const builtin = @import("builtin");

const nui = @import("nanoui");

const main = @import("main.zig");
const state_mod = @import("state.zig");
const theme = @import("theme.zig");
const titlebar = @import("titlebar.zig");

const State = state_mod.State;

fn activate() void {
    if (comptime builtin.os.tag == .macos) {
        const app = nui.objc.msg(nui.objc.Object, nui.objc.class("NSApplication"), "sharedApplication", .{});
        nui.objc.msg(void, app, "activateIgnoringOtherApps:", .{nui.objc.YES});
    }
}

fn mainClosed(context: *anyopaque, window: *nui.Window) void {
    _ = window;
    const state: *State = @ptrCast(@alignCast(context));
    state.main_window = null;
}

pub fn showMain(state: *State) void {
    if (state.main_window) |window| {
        window.show();
        window.focus();
        activate();
        return;
    }
    const app = state.app orelse return;
    const window = app.newWindow(.{
        .title = "kocr gui",
        .width = 820,
        .height = 620,
        .min_width = 640,
        .min_height = 520,
        .content = .{ .view = .init(state, main.view) },
        .on_close = .{ .ctx = state, .func = mainClosed },
    }) catch return;
    state.main_window = window;
    state.title_bar_dark = nui.isDark();
    titlebar.apply(window);
    theme.apply(state, window);
    window.show();
    window.focus();
    activate();
}
