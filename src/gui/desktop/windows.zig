//! Main window creation and activation policy.

const std = @import("std");
const builtin = @import("builtin");

const nui = @import("nanoui");

const main = @import("main.zig");
const state_mod = @import("state.zig");

const State = state_mod.State;

/// The window icon, in the container the platform loads: ICO on Windows,
/// ICNS on macOS, PNG on Linux.
pub fn windowIcon() []const u8 {
    return switch (builtin.os.tag) {
        .windows => @embedFile("../icons/kocr.ico"),
        .macos => @embedFile("../icons/kocr.icns"),
        else => @embedFile("../icons/linux/256.png"),
    };
}

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
        .icon = windowIcon(),
        // macOS: content runs under a transparent title bar, the view leaving
        // room for the traffic lights. Elsewhere the system's bar stays.
        .title_bar = if (comptime builtin.os.tag == .macos) .hidden else .default,
        .content = .{ .view = .init(state, main.view) },
        .on_close = .{ .ctx = state, .func = mainClosed },
    }) catch return;
    state.main_window = window;
    window.show();
    window.focus();
    activate();
}
