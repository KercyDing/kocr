//! Main window: daemon header, capture actions, and history.

const std = @import("std");

const nui = @import("nanoui");

const daemon = @import("daemon.zig");
const history = @import("history.zig");
const jobs = @import("jobs.zig");
const settings = @import("settings.zig");
const state_mod = @import("state.zig");

const ui = nui.ui;
const kit = nui.kit;
const State = state_mod.State;
const JobKind = jobs.JobKind;

fn actionRow(state: *State, c: *ui.Context) void {
    const busy = state.job != null;
    {
        ui.row(c, .{ .width = .fill, .gap = 8 });
        defer ui.end(c);
        const actions = [_]struct { label: []const u8, kind: JobKind }{
            .{ .label = "Copy image", .kind = .copy_image },
            .{ .label = "Save image", .kind = .save_image },
            .{ .label = "Extract text", .kind = .extract },
            .{ .label = "One line", .kind = .extract_oneline },
        };
        for (actions) |action| {
            if (kit.button(c, action.label, .{ .full_width = true, .disabled = busy }).clicked) {
                jobs.startCapture(state, action.kind);
            }
        }
    }
}

fn historyView(state: *State, c: *ui.Context) void {
    const t = c.theme;
    ui.scroll(c, .{
        .width = .fill,
        .grow = 1,
        .background = t.surface,
        .border = t.border,
        .radius = 10,
        .padding = .all(6),
        .gap = 2,
    });
    defer ui.end(c);

    if (state.rows.len == 0) {
        kit.empty(c, .{ .icon = "clock", .title = "No history yet", .description = "Captures and recognized text appear here." });
        return;
    }

    for (state.rows, 0..) |row, index| {
        const selected = state.selected == index;
        const row_box = ui.div(c)
            .row()
            .wFull()
            .h(52)
            .px(8)
            .gap(10)
            .itemsCenter()
            .rounded(6)
            .bg(if (selected) t.accent.alpha(0.12) else t.surface);
        const interaction = row_box.interaction();
        {
            defer row_box.end();
            const time_box = ui.div(c).w(150);
            ui.text(c, row.time, .{ .size = 12, .color = t.muted, .tabular = true });
            time_box.end();

            if (row.image) |bytes| {
                _ = ui.image(c, .{ .key = row.label, .bytes = bytes, .max_width = 36, .max_height = 36, .scale = 1, .radius = 4 });
                ui.text(c, row.label, .{ .size = 12, .color = t.muted, .truncate = .ellipsis });
            } else {
                ui.text(c, row.label, .{ .size = 13.5, .color = t.text, .truncate = .ellipsis });
            }
        }
        if (interaction.clicked) {
            state.selected = if (selected) null else index;
            c.changed = true;
        }
        if (interaction.hovered and row.image != null) kit.tooltip(c, interaction, row.label, .{});
    }
}

pub fn view(state: *State, c: *ui.Context) void {
    const t = c.theme;
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 12, .background = t.background });
    defer ui.end(c);

    // Header
    {
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        defer ui.end(c);
        ui.text(c, if (state.daemon_running) "Daemon: running" else "Daemon: stopped", .{ .size = 13, .color = t.muted });
        if (kit.button(c, if (state.daemon_running) "Stop" else "Start", .{}).clicked) daemon.toggleDaemon(state);
        ui.spacer(c);
        if (kit.button(c, "Settings…", .{}).clicked) settings.openSettings(state);
    }

    actionRow(state, c);

    ui.text(c, "History", .{ .size = 14, .weight = .semibold });
    historyView(state, c);

    const has_selection = state.selected != null;
    const idle = state.job == null;
    {
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        defer ui.end(c);
        if (kit.button(c, "Copy", .{ .disabled = !has_selection or !idle }).clicked) history.copySelected(state);
        if (kit.button(c, "Delete", .{ .disabled = !has_selection or !idle }).clicked) history.deleteSelected(state);
        if (kit.button(c, "Clear all", .{ .disabled = state.rows.len == 0 or !idle }).clicked) history.clearHistory(state);
        ui.spacer(c);
        ui.text(c, state.main_status, .{ .size = 12, .color = t.muted, .truncate = .ellipsis });
    }
}
