//! The Windows notification area icon (nanoui), and the single-instance handoff.

const std = @import("std");

const win32 = @import("win32");

const state_mod = @import("../desktop/state.zig");
const tray_menu = @import("menu.zig");

const State = state_mod.State;
const foundation = win32.foundation;
const kernel32 = win32.kernel32;
const threading = win32.system.threading;

/// The menu is the whole entry, as on the Mac: any click opens it.
pub fn sync(state: *State) void {
    const app = state.app orelse return;
    if (state.show_tray) {
        if (state.tray == null) {
            const items = tray_menu.items(state);
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

pub fn claim(_: std.Io) bool {
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

/// nanoui runs the tray's window itself; nothing to poll.
pub fn pump() void {}

/// A second launch asks this copy to show its window.
pub fn takeShowRequest() bool {
    const event = Win.show_event orelse return false;
    return kernel32.WaitForSingleObject(event, 0) == foundation.WAIT_OBJECT_0;
}

const Win = struct {
    var show_event: ?foundation.HANDLE = null;
};
