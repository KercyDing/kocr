//! The tray's menu, the same on every platform: the panel, the four capture
//! actions, and quit.

const nui = @import("nanoui");

const jobs = @import("../desktop/jobs.zig");
const state_mod = @import("../desktop/state.zig");
const windows = @import("../desktop/windows.zig");

const State = state_mod.State;

fn onOpen(state: *State, _: *nui.menu.Item) void {
    windows.showMain(state);
}

fn onCopy(state: *State, _: *nui.menu.Item) void {
    jobs.startCapture(state, .copy_image);
}

fn onSave(state: *State, _: *nui.menu.Item) void {
    jobs.startCapture(state, .save_image);
}

fn onExtract(state: *State, _: *nui.menu.Item) void {
    jobs.startCapture(state, .extract);
}

fn onOneLine(state: *State, _: *nui.menu.Item) void {
    jobs.startCapture(state, .extract_oneline);
}

fn onQuit(state: *State, _: *nui.menu.Item) void {
    if (state.app) |app| app.quit();
}

pub const count = 8;

/// The menu's items; the caller owns the array (both platforms copy it).
pub fn items(state: *State) [count]nui.MenuItem {
    return .{
        .{ .label = "Open kocr", .click = nui.MenuClick.of(state, onOpen) },
        .{ .is_separator = true },
        .{ .label = "Copy image", .click = nui.MenuClick.of(state, onCopy) },
        .{ .label = "Save image", .click = nui.MenuClick.of(state, onSave) },
        .{ .label = "Extract text", .click = nui.MenuClick.of(state, onExtract) },
        .{ .label = "One line", .click = nui.MenuClick.of(state, onOneLine) },
        .{ .is_separator = true },
        .{ .label = "Quit kocr", .click = nui.MenuClick.of(state, onQuit) },
    };
}
