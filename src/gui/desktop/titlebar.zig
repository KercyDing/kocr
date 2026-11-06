//! Native title bar appearance, where the platform lets an app choose it.
//! Contents follow nanoui's theme; Windows' caption is a separate DWM surface.

const builtin = @import("builtin");

const nui = @import("nanoui");

const platform = if (builtin.os.tag == .windows) struct {
    const win32 = @import("win32");

    pub fn apply(window: *nui.Window) void {
        const hwnd: win32.foundation.HWND = @ptrCast(window.hwnd orelse return);
        var dark: win32.everything.BOOL = @intFromBool(nui.isDark());
        _ = win32.everything.DwmSetWindowAttribute(
            hwnd,
            win32.everything.DWMWA_USE_IMMERSIVE_DARK_MODE,
            &dark,
            @sizeOf(win32.everything.BOOL),
        );
    }
} else struct {
    pub fn apply(window: *nui.Window) void {
        _ = window;
    }
};

pub const apply = platform.apply;
