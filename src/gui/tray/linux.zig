//! No tray on this platform; the daemon owns shortcuts.

const state_mod = @import("../desktop/state.zig");

pub fn sync(_: *state_mod.State) void {}

pub fn claim() bool {
    return true;
}

pub fn pump() void {}

pub fn takeShowRequest() bool {
    return false;
}
