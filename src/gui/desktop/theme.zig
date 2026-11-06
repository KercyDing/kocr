//! The system's light/dark preference for the window surfaces.
//!
//! nanoui asks `desktop.isDark`, which on Linux reads only GTK_THEME. KDE
//! and GNOME set the preference through GTK's settings instead, so here
//! GTK's own `gtk-application-prefer-dark-theme` is read and applied to the
//! surfaces.

const std = @import("std");
const builtin = @import("builtin");

const nui = @import("nanoui");

const state_mod = @import("state.zig");

const State = state_mod.State;

const platform = if (builtin.os.tag == .linux) Linux else Other;

/// Re-reads the preference; repaints when it changed.
pub const sync = platform.sync;
/// Gives a window that was just made the current preference.
pub const apply = platform.apply;

/// The GTK and GObject entry points read below.
const Gtk = struct {
    settings_get_default: *const fn () callconv(.c) ?*anyopaque,
    object_get: *const fn (?*anyopaque, [*:0]const u8, ...) callconv(.c) void,
};

const Linux = struct {
    var gtk: ?Gtk = null;
    var looked = false;

    fn load() ?Gtk {
        if (looked) return gtk;
        looked = true;
        // NOLOAD: only the GTK nanoui picked is loaded already, and asking
        // the other version before its init would read no settings.
        const lib = std.c.dlopen("libgtk-4.so.1", .{ .NOW = true, .NOLOAD = true }) orelse
            std.c.dlopen("libgtk-3.so.0", .{ .NOW = true, .NOLOAD = true }) orelse return null;
        const settings = std.c.dlsym(lib, "gtk_settings_get_default") orelse return null;
        var get = std.c.dlsym(lib, "g_object_get");
        if (get == null) {
            if (std.c.dlopen("libgobject-2.0.so.0", .{ .NOW = true, .NOLOAD = true })) |h| {
                get = std.c.dlsym(h, "g_object_get");
            }
        }
        gtk = .{
            .settings_get_default = @ptrCast(@alignCast(settings)),
            .object_get = @ptrCast(@alignCast(get orelse return null)),
        };
        return gtk;
    }

    fn gtkPreferDark() ?bool {
        const api = load() orelse return null;
        const settings = api.settings_get_default() orelse return null;
        var prefer: c_int = 0;
        api.object_get(settings, "gtk-application-prefer-dark-theme", &prefer, @as(?*anyopaque, null));
        return prefer != 0;
    }

    fn containsDark(name: []const u8) bool {
        var i: usize = 0;
        while (i + 4 <= name.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(name[i .. i + 4], "dark")) return true;
        }
        return false;
    }

    fn isDark(environ: *const std.process.Environ.Map) bool {
        // GTK_THEME is an explicit override, as it is to GTK itself.
        if (environ.get("GTK_THEME")) |name| return containsDark(name);
        return gtkPreferDark() orelse nui.isDark();
    }

    fn set(window: *nui.Window, dark: bool) void {
        if (window.surface) |surface| {
            surface.theme_override = if (dark) nui.ui.Theme.dark_theme else nui.ui.Theme.light;
        }
        window.redraw();
    }

    pub fn sync(state: *State) void {
        const dark = isDark(state.environ);
        if (state.dark == dark) return;
        state.dark = dark;
        for ([_]?*nui.Window{ state.main_window, state.settings_window }) |maybe| {
            if (maybe) |window| set(window, dark);
        }
    }

    pub fn apply(state: *State, window: *nui.Window) void {
        const dark = isDark(state.environ);
        state.dark = dark;
        set(window, dark);
    }
};

const Other = struct {
    // macOS reads NSAppearance and Windows the registry, and both follow
    // changes themselves (nanoui's surface).
    pub fn sync(state: *State) void {
        _ = state;
    }

    pub fn apply(state: *State, window: *nui.Window) void {
        _ = state;
        _ = window;
    }
};
