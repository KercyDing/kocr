//! Main window: daemon header, capture actions, and history.

const std = @import("std");
const builtin = @import("builtin");

const nui = @import("nanoui");

const daemon = @import("daemon_linux.zig");
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

fn previewPanel(c: *ui.Context, trigger: ui.Interaction, fallback: ui.Size, padding: f32, width: ?f32) ?ui.Div {
    const t = c.theme;
    const tip_key = c.print("history-preview-{x}", .{trigger.id});
    // Rest for a second before showing the preview.
    const rested = ui.motion.number(c, tip_key, if (trigger.hovered and !trigger.pressed) 1 else 0, if (trigger.hovered) .{ .tween = .{ .duration = 1.0, .ease = .linear } } else .instant);
    const anchor = trigger.rect orelse return null;
    const show = trigger.hovered and rested >= 0.999;
    const f = ui.motion.present(c, tip_key, show, .{
        .initial = .{ .opacity = 0, .scale = 0.96 },
        .exit = .{ .opacity = 0 },
        .transition = .{ .tween = .{ .duration = 0.12 } },
    }) orelse return null;
    const id = c.peekId(null);
    const size = if (c.rects.get(id)) |r| ui.Size{ .w = r.w, .h = r.h } else fallback;
    var x = anchor.x + (anchor.w - size.w) / 2;
    var y = anchor.y - size.h - 8;
    if (y < 6) y = anchor.y + anchor.h + 8;
    x = std.math.clamp(x, 6, @max(6, c.size.w - size.w - 6));
    y = std.math.clamp(y, 6, @max(6, c.size.h - size.h - 6));
    var d = ui.div(c)
        .fixed()
        .offset(x, y)
        .layer(30)
        .p(padding)
        .rounded(8)
        .bg(t.surface)
        .border(t.border)
        .shadow(.{ .color = t.shadow.alpha(0.6), .blur = 16, .y = 6 });
    if (width) |w| d = d.w(w);
    return d.motion(f);
}

/// Draws a picture filling `box`, trimmed to the box's proportions: history
/// rows keep one height whatever shape the capture is, without stretching it.
fn imageCover(c: *ui.Context, key: []const u8, bytes: []const u8, box: ui.Size, radius: f32) bool {
    const source = ui.imageSize(c, key, bytes) orelse return false;
    const src_w = @max(source.w, 1);
    const src_h = @max(source.h, 1);
    const scale = @max(box.w / src_w, box.h / src_h);
    const shown_w = box.w / scale;
    const shown_h = box.h / scale;
    const l = 0.5 * (1 - shown_w / src_w);
    const t = 0.5 * (1 - shown_h / src_h);
    return ui.image(c, .{
        .key = key,
        .source = .{ .encoded = bytes },
        .box = box,
        .part = .{ l, t, 1 - l, 1 - t },
        .radius = radius,
        .scale = 1,
    });
}

fn imagePreviewTooltip(c: *ui.Context, trigger: ui.Interaction, key: []const u8, bytes: []const u8) void {
    var d = previewPanel(c, trigger, .{ .w = 368, .h = 248 }, 4, null) orelse return;
    d = d.w(368).h(248);
    defer d.end();
    const inner = ui.div(c).wFull().hFull().itemsCenter().justifyCenter();
    defer inner.end();
    _ = ui.image(c, .{ .key = key, .source = .{ .encoded = bytes }, .max_width = 360, .max_height = 240, .radius = 6, .scale = 1 });
}

fn textPreviewTooltip(c: *ui.Context, trigger: ui.Interaction, text: []const u8) void {
    const style = ui.TextStyle{ .size = 12.5, .wrap = true, .color = c.theme.text };
    // Measure now, so the panel is its final size on the first frame instead
    // of moving once layout has measured it.
    const lines = c.text.wrap(text, style, 346);
    const content_h = @as(f32, @floatFromInt(lines.len)) * c.text.lineHeight(style);
    const panel_h = std.math.clamp(content_h + 20, 48, 280);
    var d = previewPanel(c, trigger, .{ .w = 368, .h = panel_h }, 10, 368) orelse return;
    d = d.h(panel_h);
    if (content_h + 20 > 280) d = d.scrollY();
    defer d.end();
    ui.text(c, text, style);
}

fn historyView(state: *State, c: *ui.Context) void {
    const t = c.theme;
    const empty = state.rows.len == 0;
    ui.scroll(c, .{
        .width = .fill,
        .grow = 1,
        .background = t.surface,
        .border = t.border,
        .radius = 10,
        .padding = .all(6),
        .gap = 2,
        .justify = if (empty) .center else .start,
        .align_items = if (empty) .center else .start,
        .scrollbar = .{ .overlay = t.muted },
    });
    defer ui.end(c);

    if (empty) {
        ui.text(c, "No history yet", .{ .size = 13, .color = t.muted });
        return;
    }

    const busy = state.job != null;
    var copy_index: ?usize = null;
    var delete_index: ?usize = null;
    for (state.rows, 0..) |row, index| {
        const row_box = ui.div(c)
            .row()
            .wFull()
            .h(64)
            .px(10)
            .gap(12)
            .itemsCenter()
            .rounded(6)
            .bg(t.surface);
        const interaction = row_box.interaction();
        if (interaction.hovered) _ = row_box.bg(t.surface_hover);
        {
            defer row_box.end();
            const time_box = ui.div(c).w(118);
            ui.text(c, row.time, .{ .size = 12, .color = t.muted, .tabular = true });
            time_box.end();

            const content = ui.div(c).row().grow().gap(12).itemsCenter();
            {
                defer content.end();
                if (row.image) |bytes| {
                    const key = c.print("history-thumb-{s}", .{row.label});
                    if (!imageCover(c, key, bytes, .{ .w = 56, .h = 48 }, 6)) {
                        ui.text(c, row.label, .{ .size = 12, .color = t.muted, .truncate = .ellipsis });
                    }
                } else {
                    ui.text(c, row.label, .{ .size = 13.5, .color = t.text, .truncate = .ellipsis });
                }
            }

            if (kit.button(c, "Copy", .{ .size = .sm, .disabled = busy }).clicked) copy_index = index;
            if (kit.button(c, "Delete", .{ .size = .sm, .disabled = busy }).clicked) delete_index = index;
        }
        if (interaction.hovered) {
            if (row.image) |bytes| {
                const key = c.print("history-preview-{s}", .{row.label});
                imagePreviewTooltip(c, interaction, key, bytes);
            } else if (row.detail) |text| {
                textPreviewTooltip(c, interaction, text);
            }
        }
    }
    if (copy_index) |index| history.copyRecord(state, index);
    if (delete_index) |index| history.deleteRecord(state, index);
}

pub fn view(state: *State, c: *ui.Context) void {
    const t = c.theme;
    const idle = state.job == null;
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(16), .gap = 12, .background = t.background });
    defer ui.end(c);

    // Header
    {
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        defer ui.end(c);
        if (builtin.os.tag == .linux) {
            if (ui.toggle(c, "Daemon", &state.daemon_running)) daemon.applyDaemon(state);
        }
        ui.spacer(c);
        if (kit.button(c, "Settings", .{}).clicked) settings.openSettings(state);
    }

    actionRow(state, c);

    {
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center, .padding = .{ .top = 8 } });
        defer ui.end(c);
        ui.text(c, "History", .{ .size = 14, .weight = .semibold });
        ui.spacer(c);
        if (kit.button(c, "Clear all", .{ .size = .sm, .disabled = state.rows.len == 0 or !idle }).clicked) history.clearHistory(state);
    }
    historyView(state, c);
}
