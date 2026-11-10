//! A destructive icon that asks twice: the first click arms it in red, the
//! second one goes through, and a press anywhere else puts it back.

const nui = @import("nanoui");

const ui = nui.ui;
const kit = nui.kit;

/// `armed` is the caller's state. `id` names the button's two steps apart: with
/// one node id, the release that armed it would count as the confirming click.
/// Returns true on the confirming click.
pub fn button(c: *ui.Context, armed: *bool, id: []const u8, tooltip: []const u8, red_tooltip: []const u8, disabled: bool) bool {
    if (armed.*) {
        ui.key(c, c.print("{s}-confirm", .{id}));
        const confirm = kit.iconButton(c, "checkmark", .{ .variant = .danger, .size = .sm, .tooltip = red_tooltip, .disabled = disabled });
        if (confirm.clicked) {
            armed.* = false;
            c.changed = true;
            return true;
        }
        if (c.input.pressed and !confirm.hovered) {
            armed.* = false;
            c.changed = true;
        }
        return false;
    }
    ui.key(c, id);
    if (kit.iconButton(c, "trash", .{ .variant = .ghost, .size = .sm, .tooltip = tooltip, .disabled = disabled }).clicked) {
        armed.* = true;
        c.changed = true;
    }
    return false;
}
