//! The settings tab: model, shortcuts, autostart, and saving.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("core");
const nui = @import("nanoui");

const jobs = @import("jobs.zig");
const model = @import("model.zig");
const about = @import("about.zig");
const confirm = @import("confirm.zig");
const state_mod = @import("state.zig");
const tray = @import("../tray/root.zig");

const config = core.config;
const agent = builtin.os.tag == .macos or builtin.os.tag == .windows;

const ui = nui.ui;
const kit = nui.kit;
const State = state_mod.State;

const shortcut_labels = [4][]const u8{ "Copy image", "Save image", "Extract text", "One line" };

const section_title: ui.TextStyle = .{ .size = 14, .weight = .semibold };

/// A titled group: its title and its content a gap apart.
fn section(c: *ui.Context) void {
    ui.column(c, .{ .width = .fill, .gap = 8 });
}

/// Fills the tab from the config and the model folder, when it is opened.
pub fn load(state: *State) void {
    var parsed = config.load(state.allocator, state.io, state.environ) catch return;
    defer parsed.deinit();
    const values = [_]?[]const u8{
        parsed.value.shortcuts.copy,
        parsed.value.shortcuts.save,
        parsed.value.shortcuts.ocr,
        parsed.value.shortcuts.oneline,
    };
    for (values, 0..) |value, index| {
        if (state.shortcuts[index]) |old| state.allocator.free(old);
        state.shortcuts[index] = if (value) |text| state.allocator.dupe(u8, text) catch null else null;
    }
    state.show_tray = parsed.value.ui.tray;
    state.theme = parsed.value.ui.theme;
    state.autostart = core.autostart.enabled(state.io, state.allocator, state.environ) catch false;
}

fn persistSettings(state: *State, apply_autostart: bool, apply_tray: bool) void {
    var parsed = config.load(state.allocator, state.io, state.environ) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setSettingsStatus(std.fmt.bufPrint(&buffer, "Config error: {s}", .{@errorName(err)}) catch "Config error");
        return;
    };
    defer parsed.deinit();
    parsed.value.shortcuts.copy = state.shortcuts[0];
    parsed.value.shortcuts.save = state.shortcuts[1];
    parsed.value.shortcuts.ocr = state.shortcuts[2];
    parsed.value.shortcuts.oneline = state.shortcuts[3];
    parsed.value.ui.tray = state.show_tray;
    parsed.value.ui.theme = state.theme;
    config.save(state.allocator, state.io, state.environ, parsed.value) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setSettingsStatus(std.fmt.bufPrint(&buffer, "Could not save config: {s}", .{@errorName(err)}) catch "Could not save config");
        return;
    };
    core.reloadHotkeys();
    if (apply_tray) tray.sync(state);
    if (apply_autostart) {
        const executable = std.process.executablePathAlloc(state.io, state.allocator) catch null;
        defer if (executable) |path| state.allocator.free(path);
        core.autostart.set(state.io, state.allocator, state.environ, state.autostart, executable orelse "") catch |err| {
            var buffer: [256]u8 = undefined;
            state.setSettingsStatus(std.fmt.bufPrint(&buffer, "Could not update autostart: {s}", .{@errorName(err)}) catch "Could not update autostart");
            return;
        };
    }
    state.setSettingsStatus("Saved");
}

fn setShortcut(state: *State, index: usize, text: []const u8) void {
    const copy = state.allocator.dupe(u8, text) catch return;
    if (state.shortcuts[index]) |old| state.allocator.free(old);
    state.shortcuts[index] = copy;
    persistSettings(state, false, false);
}

fn clearShortcut(state: *State, index: usize) void {
    if (state.shortcuts[index]) |old| state.allocator.free(old);
    state.shortcuts[index] = null;
    persistSettings(state, false, false);
}

fn buildShortcut(state: *State, index: usize, ctrl: bool, alt: bool, shift: bool, meta: bool, name: []const u8) void {
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}{s}{s}{s}{s}", .{
        if (ctrl) "Ctrl+" else "",
        if (alt) "Alt+" else "",
        if (shift) "Shift+" else "",
        if (meta) "Meta+" else "",
        name,
    }) catch return;
    setShortcut(state, index, text);
}

fn keyLabel(cp: u21, scratch: *[8]u8) ?[]const u8 {
    if (cp >= 'a' and cp <= 'z') {
        scratch[0] = @intCast(cp - 'a' + 'A');
        return scratch[0..1];
    }
    if (cp >= 'A' and cp <= 'Z') {
        scratch[0] = @intCast(cp);
        return scratch[0..1];
    }
    if (cp >= '0' and cp <= '9') {
        scratch[0] = @intCast(cp);
        return scratch[0..1];
    }
    return switch (cp) {
        0x1b => "Escape",
        '\t' => "Tab",
        '\r' => "Enter",
        ' ' => "Space",
        ui.Shortcut.up => "Up",
        ui.Shortcut.down => "Down",
        ui.Shortcut.left => "Left",
        ui.Shortcut.right => "Right",
        '\'' => "Apostrophe",
        ',' => "Comma",
        '-' => "Minus",
        '.' => "Period",
        '/' => "Slash",
        ';' => "Semicolon",
        '=' => "Equal",
        '[' => "BracketLeft",
        '\\' => "Backslash",
        ']' => "BracketRight",
        '`' => "Grave",
        else => null,
    };
}

fn keyEnumName(key: anytype) ?[]const u8 {
    return switch (key) {
        .backspace => "Backspace",
        .delete => "Delete",
        .left => "Left",
        .right => "Right",
        .up => "Up",
        .down => "Down",
        .home => "Home",
        .end => "End",
        .enter => "Enter",
        .tab => "Tab",
        .escape => "Escape",
        .page_up => "PageUp",
        .page_down => "PageDown",
        .f1 => "F1",
        .f2 => "F2",
        .f3 => "F3",
        .f4 => "F4",
        .f5 => "F5",
        .f6 => "F6",
        .f7 => "F7",
        .f8 => "F8",
        .f9 => "F9",
        .f10 => "F10",
        .f11 => "F11",
        .f12 => "F12",
    };
}

fn captureShortcut(state: *State, c: *ui.Context, index: usize) void {
    if (c.input.shortcut) |shortcut| {
        c.input.shortcut = null;
        c.shortcut_taken = true;
        var scratch: [8]u8 = undefined;
        if (keyLabel(shortcut.key, &scratch)) |name| {
            buildShortcut(state, index, shortcut.ctrl, shortcut.alt, shortcut.shift, shortcut.cmd, name);
            c.changed = true;
        }
        return;
    }
    if (c.input.key) |key| {
        c.input.key = null;
        switch (key) {
            .delete, .backspace => {
                clearShortcut(state, index);
                c.changed = true;
                return;
            },
            else => {
                if (keyEnumName(key)) |name| {
                    buildShortcut(state, index, c.input.ctrl, c.input.alt, c.input.shift, c.input.cmd, name);
                    c.changed = true;
                }
                return;
            },
        }
    }
    if (c.input.chars.len > 0) {
        const first = c.input.chars[0];
        const length = std.unicode.utf8ByteSequenceLength(first) catch 1;
        const end = @min(length, c.input.chars.len);
        const cp = std.unicode.utf8Decode(c.input.chars[0..end]) catch 0;
        c.input.chars = "";
        if (cp != 0) {
            var scratch: [8]u8 = undefined;
            if (keyLabel(cp, &scratch)) |name| {
                buildShortcut(state, index, c.input.ctrl, c.input.alt, c.input.shift, c.input.cmd, name);
                c.changed = true;
            }
        }
    }
}

fn shortcutRow(state: *State, c: *ui.Context, index: usize, label: []const u8) void {
    const t = c.theme;
    ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
    defer ui.end(c);

    const label_box = ui.div(c).w(140);
    ui.text(c, label, .{ .size = 13 });
    label_box.end();

    const box = ui.div(c).row().grow().h(32).px(10).gap(6).itemsCenter().rounded(6);
    const interaction = c.interact(box.index, .{ .focusable = true });
    const node = c.node(box.index);
    node.style.background = if (interaction.focused) t.surface_hover else t.surface;
    node.style.border = if (interaction.focused) t.accent else t.border;
    if (interaction.focused) captureShortcut(state, c, index);
    {
        defer box.end();
        const value = state.shortcuts[index];
        if (value) |text| {
            ui.text(c, text, .{ .size = 13, .color = t.text });
        } else if (interaction.focused) {
            ui.text(c, "Press shortcut…", .{ .size = 13, .color = t.muted });
        } else {
            ui.text(c, "Not set", .{ .size = 13, .color = t.muted });
        }
        ui.spacer(c);
        if (state.shortcuts[index] != null) {
            if (kit.iconButton(c, "xmark", .{ .size = .xs, .tooltip = "Clear shortcut" }).clicked) {
                clearShortcut(state, index);
                c.focus = 0;
                c.changed = true;
            }
        } else if (interaction.focused) {
            ui.text(c, "recording", .{ .size = 11, .color = t.muted });
        }
    }
}

fn installProgress(state: *State, c: *ui.Context) void {
    const job = state.job orelse return;
    if (job.kind != .install or job.done.load(.acquire)) return;
    const known = job.progress_known.load(.acquire);
    const value: ?f32 = if (known)
        @as(f32, @floatFromInt(job.progress.load(.acquire))) / 1000.0
    else
        null;
    kit.progress(c, value, .{ .width = .fill, .height = 6 });
}

pub fn page(state: *State, c: *ui.Context) void {
    const t = c.theme;
    ui.column(c, .{ .width = .fill, .grow = 1, .gap = 10 });
    defer ui.end(c);
    {
        // One gap between sections; a title sits one smaller gap above its own.
        ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 20 });
        defer ui.end(c);

        {
            section(c);
            defer ui.end(c);
            ui.text(c, "Model", section_title);
            {
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
                defer ui.end(c);
                var index = state.profile_index;
                if (kit.tabs(c, &model.profiles, &index, .{ .variant = .segmented })) {
                    state.profile_index = index;
                    state.confirm_remove = false;
                    _ = model.updateModelStatus(state);
                    model.saveSelection(state);
                    state.redraw();
                }
                if (state.installed) {
                    if (confirm.button(c, &state.confirm_remove, "model-remove", "Remove model", "Click again to remove", state.job != null)) {
                        jobs.startModel(state, .remove);
                    }
                } else {
                    if (kit.iconButton(c, "plus", .{ .variant = .ghost, .size = .sm, .tooltip = "Install model", .disabled = state.job != null }).clicked) {
                        jobs.startModel(state, .install);
                    }
                }
            }
            installProgress(state, c);
        }

        {
            section(c);
            defer ui.end(c);
            ui.text(c, "Shortcuts", section_title);
            for (0..state.shortcuts.len) |index| shortcutRow(state, c, index, shortcut_labels[index]);
        }

        {
            section(c);
            defer ui.end(c);
            ui.text(c, "Theme", section_title);
            const names = [_][]const u8{ "Auto", "Light", "Dark" };
            var index: usize = @backingInt(state.theme);
            if (kit.tabs(c, &names, &index, .{ .variant = .segmented })) {
                state.theme = @fromBackingInt(@intCast(index));
                persistSettings(state, false, false);
                state.redraw();
            }
        }

        {
            // The toggles belong together, and have no title of their own.
            section(c);
            defer ui.end(c);
            if (ui.checkbox(c, if (agent) "Launch at login" else "Start daemon at login", &state.autostart)) {
                persistSettings(state, true, false);
            }
            if (agent) {
                if (ui.checkbox(c, "Show menu bar icon", &state.show_tray)) persistSettings(state, false, true);
            }
        }
    }

    {
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        defer ui.end(c);
        const status = ui.div(c).grow();
        ui.text(c, state.settings_status, .{ .size = 12, .color = t.muted, .truncate = .ellipsis });
        status.end();
        if (kit.button(c, "About kocr", .{ .variant = .ghost, .size = .sm }).clicked) about.openAbout(state);
    }
}
