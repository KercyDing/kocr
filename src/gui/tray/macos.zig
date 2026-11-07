//! The menu bar item (nanoui).

const nui = @import("nanoui");

const state_mod = @import("../desktop/state.zig");
const windows = @import("../desktop/windows.zig");

const State = state_mod.State;
const icon_size = 40;
const template = @embedFile("../icons/kocr-tray.bgra");

fn onOpen(state: *State, _: *nui.menu.Item) void {
    windows.showMain(state);
}

fn onQuit(state: *State, _: *nui.menu.Item) void {
    if (state.app) |app| app.quit();
}

/// Creates the item once, then only its visibility follows the setting.
pub fn sync(state: *State) void {
    const app = state.app orelse return;

    if (state.tray == null) {
        const items = [_]nui.MenuItem{
            .{ .label = "Open kocr", .click = nui.MenuClick.of(state, onOpen) },
            .{ .is_separator = true },
            .{ .label = "Quit kocr", .click = nui.MenuClick.of(state, onQuit) },
        };
        state.tray = app.newTray(.{
            .symbol = "text.viewfinder",
            .tooltip = "kocr",
            .menu = &items,
        }) catch null;
        if (state.tray) |tray| tray.setImage(template[0..], icon_size, icon_size, 2.0, true);
    }

    const tray = state.tray orelse return;
    nui.objc.msg(void, tray.item, "setVisible:", .{if (state.show_tray) nui.objc.YES else nui.objc.NO});
}

pub fn claim() bool {
    return true;
}

pub fn pump() void {}

pub fn takeShowRequest() bool {
    return false;
}
