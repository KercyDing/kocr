//! The status notifier item (nanoui's Linux tray), and the one instance that owns it.

const std = @import("std");

const nui = @import("nanoui");

const state_mod = @import("../desktop/state.zig");
const tray_menu = @import("menu.zig");
const windows = @import("../desktop/windows.zig");

const State = state_mod.State;
/// The panel's tray icon size; hosts that want another scale it.
const icon_size = 22;
/// BGRA, premultiplied: `icons/linux/256.png` at `icon_size`, as nanoui's
/// `setImage` wants it. Regenerate with:
///   ffmpeg -i icons/linux/256.png -vf "scale=22:22:flags=lanczos,premultiply=inplace=1" \
///     -pix_fmt bgra -f rawvideo icons/kocr-tray-linux.bgra
const icon = @embedFile("../icons/kocr-tray-linux.bgra");

/// The running instance's listener. Its name is abstract (`@kocr-show-<uid>`),
/// so a process that dies leaves nothing behind for the next one to trip on.
var server: ?std.Io.net.Server = null;
var watching = false;
var address_bytes: [1 + "kocr-show-4294967295".len]u8 = undefined;

/// The first kocr owns the name; a second one connects to it, which asks it for
/// its window, and stops.
pub fn claim(io: std.Io) bool {
    const address = showAddress();
    const s = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => {
            const stream = address.connect(io) catch return false;
            stream.close(io);
            return false;
        },
        // A second kocr is worse, but no kocr at all is worse still.
        else => return true,
    };
    server = s;
    return true;
}

fn showAddress() std.Io.net.UnixAddress {
    const name = std.fmt.bufPrint(address_bytes[1..], "kocr-show-{d}", .{std.os.linux.getuid()}) catch unreachable;
    address_bytes[0] = 0;
    return std.Io.net.UnixAddress.init(address_bytes[0 .. 1 + name.len]) catch unreachable;
}

/// Creates the item once the setting allows it, and destroys it when it does
/// not: a status notifier item has no visibility of its own.
pub fn sync(state: *State) void {
    const app = state.app orelse return;

    if (!watching and server != null) {
        if (nui.fdwatch.readable(server.?.socket.handle, state, onShow)) |_| {
            watching = true;
        } else |_| {}
    }

    if (state.show_tray) {
        if (state.tray == null) {
            const items = tray_menu.items(state);
            state.tray = app.newTray(.{ .tooltip = "kocr", .menu = &items }) catch null;
            if (state.tray) |tray| tray.setImage(icon[0..], icon_size, icon_size, 1.0, false);
        }
    } else if (state.tray) |tray| {
        tray.destroy();
        state.tray = null;
    }
}

/// A second launch connected: show the window it asked for.
fn onShow(context: ?*anyopaque) callconv(.c) void {
    const state: *State = @ptrCast(@alignCast(context orelse return));
    const s = if (server) |*s| s else return;
    const stream = s.accept(state.io) catch return;
    stream.close(state.io);
    windows.showMain(state);
}

/// The window asks through the socket instead.
pub fn pump() void {}

pub fn takeShowRequest() bool {
    return false;
}
