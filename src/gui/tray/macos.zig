//! The menu bar item (nanoui).

const nui = @import("nanoui");

const state_mod = @import("../desktop/state.zig");
const tray_menu = @import("menu.zig");

const State = state_mod.State;
const icon_size = 40;
const template = @embedFile("../icons/kocr-tray.bgra");

/// Creates the item once, then only its visibility follows the setting.
pub fn sync(state: *State) void {
    const app = state.app orelse return;

    if (state.tray == null) {
        const items = tray_menu.items(state);
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
