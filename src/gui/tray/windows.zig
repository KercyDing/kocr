//! The Windows notification area icon (perch), and the single-instance handoff.

const std = @import("std");

const perch = @import("perch");
const win32 = @import("win32");

const state_mod = @import("../desktop/state.zig");
const windows = @import("../desktop/windows.zig");

const State = state_mod.State;
const foundation = win32.foundation;
const kernel32 = win32.kernel32;
const threading = win32.system.threading;

const icon: perch.Icon = .{ .bytes = @embedFile("../icons/kocr.ico") };

const Win = struct {
    var tray: ?*perch.Tray = null;
    var menu: perch.Menu = undefined;
    var menu_ready: bool = false;
    var open_id: perch.MenuItem.Id = 0;
    var quit_id: perch.MenuItem.Id = 0;
    var show_event: ?foundation.HANDLE = null;
};

fn onActivate(context: ?*anyopaque, _: *perch.Tray, id: perch.MenuItem.Id) void {
    const state: *State = @ptrCast(@alignCast(context.?));
    if (id == Win.open_id) {
        windows.showMain(state);
    } else if (id == Win.quit_id) {
        if (state.app) |app| app.quit();
    }
}

fn onClick(context: ?*anyopaque, _: *perch.Tray, event: perch.ClickEvent) void {
    switch (event.button) {
        .left => {
            const state: *State = @ptrCast(@alignCast(context.?));
            windows.showMain(state);
        },
        // Right clicks open the menu; perch pops it after this callback returns,
        // so popping it here too would show it twice. Middle clicks are unused.
        .right, .middle => {},
    }
}

fn create(state: *State) void {
    Win.menu = perch.Menu.init(state.allocator);
    Win.menu_ready = true;
    Win.open_id = Win.menu.addItem("Open kocr") catch return;
    Win.menu.addSeparator() catch return;
    Win.quit_id = Win.menu.addItem("Quit kocr") catch return;
    Win.tray = perch.Tray.create(state.allocator, .{
        .io = state.io,
        .app_id = "io.github.KercyDing.kocr",
        .tooltip = "kocr",
        .icon = icon,
        .menu = &Win.menu,
        .left_click = .activate,
        .handler = .{ .ctx = state, .on_activate = onActivate, .on_click = onClick },
    }) catch null;
}

fn destroy() void {
    if (Win.tray) |tray| tray.destroy();
    Win.tray = null;
    if (Win.menu_ready) {
        Win.menu.deinit();
        Win.menu_ready = false;
    }
}

pub fn sync(state: *State) void {
    if (state.show_tray) {
        if (Win.tray == null) create(state);
    } else {
        destroy();
    }
}

pub fn pump() void {
    if (Win.tray) |tray| tray.pump() catch {};
}

/// A second launch asks this copy to show its window.
pub fn takeShowRequest() bool {
    const event = Win.show_event orelse return false;
    return kernel32.WaitForSingleObject(event, 0) == foundation.WAIT_OBJECT_0;
}

pub fn claim() bool {
    perch.awareDpi();
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
