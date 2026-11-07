//! The optional menu bar item.

const builtin = @import("builtin");

const nui = @import("nanoui");

const state_mod = @import("state.zig");
const windows = @import("windows.zig");

const State = state_mod.State;

fn onOpen(state: *State, _: *nui.menu.Item) void {
    windows.showMain(state);
}

fn onQuit(state: *State, _: *nui.menu.Item) void {
    if (state.app) |app| app.quit();
}

/// Creates the item once, then only its visibility follows the setting.
const impl = if (builtin.os.tag == .macos) struct {
    fn sync(state: *State) void {
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
        }

        const tray = state.tray orelse return;
        nui.objc.msg(void, tray.item, "setVisible:", .{if (state.show_tray) nui.objc.YES else nui.objc.NO});
    }
} else struct {
    fn sync(_: *State) void {}
};

pub fn sync(state: *State) void {
    impl.sync(state);
}
