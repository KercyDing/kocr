//! The Windows notification area icon (nanoui), and the single-instance handoff.

const nui = @import("nanoui");
const win32 = @import("win32");

const state_mod = @import("../desktop/state.zig");
const windows = @import("../desktop/windows.zig");

const State = state_mod.State;
const foundation = win32.foundation;
const kernel32 = win32.kernel32;
const threading = win32.system.threading;

fn onOpen(state: *State, _: *nui.menu.Item) void {
    windows.showMain(state);
}

fn onQuit(state: *State, _: *nui.menu.Item) void {
    if (state.app) |app| app.quit();
}

/// The menu is the whole entry, as on the Mac: any click opens it.
pub fn sync(state: *State) void {
    const app = state.app orelse return;
    if (state.show_tray) {
        if (state.tray == null) {
            const items = [_]nui.MenuItem{
                .{ .label = "Open kocr", .click = nui.MenuClick.of(state, onOpen) },
                .{ .is_separator = true },
                .{ .label = "Quit kocr", .click = nui.MenuClick.of(state, onQuit) },
            };
            // The icon is the executable's own resource (icons/kocr.rc).
            state.tray = app.newTray(.{
                .tooltip = "kocr",
                .menu = &items,
            }) catch null;
        }
    } else if (state.tray) |tray| {
        tray.destroy();
        state.tray = null;
    }
}

/// nanoui runs the tray's window itself; nothing to poll.
pub fn pump() void {}

/// A second launch asks this copy to show its window.
pub fn takeShowRequest() bool {
    const event = Win.show_event orelse return false;
    return kernel32.WaitForSingleObject(event, 0) == foundation.WAIT_OBJECT_0;
}

pub fn claim() bool {
    const name = win32.zig.L("Local\\kocr-show-window");
    const event = kernel32.CreateEventW(null, 0, 0, name);
    if (event == null) return true;
    if (kernel32.GetLastError() == foundation.ERROR_ALREADY_EXISTS) {
        if (kernel32.OpenEventW(threading.EVENT_MODIFY_STATE, 0, name)) |other| {
            _ = kernel32.SetEvent(other);
            _ = kernel32.CloseHandle(other);
        }
        _ = kernel32.CloseHandle(event);
        return false;
    }
    Win.show_event = event;
    return true;
}

const Win = struct {
    var show_event: ?foundation.HANDLE = null;
};
