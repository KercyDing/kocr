//! Main window: the history and settings, behind a glass sidebar.

const std = @import("std");
const builtin = @import("builtin");

const nui = @import("nanoui");

const about = @import("about.zig");
const confirm = @import("confirm.zig");
const history = @import("history.zig");
const settings = @import("settings.zig");
const state_mod = @import("state.zig");

const ui = nui.ui;
const kit = nui.kit;
const State = state_mod.State;

/// The rows' buttons sit a scroll padding (6) and a row padding (10) in from
/// the panel's edge; the toolbar keeps the same inset, so the trash lands over
/// the rows' own buttons.
const row_inset: f32 = 16;

const rail_width: f32 = 208;

const title_bar_height: f32 = 32;

const top: f32 = switch (builtin.os.tag) {
    .windows => title_bar_height + 12,
    .macos => 44,
    else => 16,
};

const rail_top: f32 = switch (builtin.os.tag) {
    .windows => 10,
    .macos => 44,
    else => 12,
};

fn navItem(c: *ui.Context, icon: []const u8, label: []const u8, on: bool) bool {
    const t = c.theme;
    var row = ui.div(c).row().wFull().h(32).px(10).gap(10).itemsCenter().rounded(8).control();
    const it = row.interaction();
    if (on) {
        row = row.bg(t.surface_hover);
    } else if (it.hovered) {
        row = row.bg(t.surface_hover.alpha(0.5));
    }
    {
        defer row.end();
        const fg = if (on) t.text else t.muted;
        ui.icon(c, icon, .{ .size = 15, .weight = .medium, .color = fg });
        ui.text(c, label, .{ .size = 13, .weight = .medium, .color = fg });
    }
    return it.clicked;
}

const Caption = enum { minimize, maximize, close };

/// One of a Windows title bar's buttons.
fn captionButton(c: *ui.Context, icon: []const u8, kind: Caption, window: *nui.Window) void {
    const t = c.theme;
    var d = ui.div(c).row().w(46).h(title_bar_height).itemsCenter().justifyCenter().control();
    // The system hit-tests this as its maximize button, and still sends the click.
    if (kind == .maximize) c.node(d.index).style.window_maximize = true;
    const it = d.interaction();
    if (it.hovered) d = d.bg(if (kind == .close) t.danger else t.surface_hover);
    {
        defer d.end();
        ui.icon(c, icon, .{
            .size = 12,
            .weight = .medium,
            .color = if (kind == .close and it.hovered) ui.Color.white else t.text,
        });
    }
    if (!it.clicked) return;
    switch (kind) {
        .minimize => window.minimize(),
        .maximize => window.zoom(),
        .close => window.close(),
    }
}

/// The app-drawn Windows title bar: a drag band and the system's buttons.
fn titleBar(state: *State, c: *ui.Context) void {
    const window = state.main_window orelse return;
    var band = ui.div(c).row().absolute().wFull().h(title_bar_height).itemsCenter();
    c.node(band.index).style.window_drag = true;
    defer band.end();
    ui.spacer(c);
    captionButton(c, "minus", .minimize, window);
    captionButton(c, "rectangle.on.rectangle", .maximize, window);
    captionButton(c, "xmark", .close, window);
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

            if (kit.iconButton(c, "doc.on.doc", .{ .variant = .default, .size = .sm, .tooltip = "Copy", .disabled = busy }).clicked) copy_index = index;
            if (kit.iconButton(c, "xmark", .{ .variant = .default, .size = .sm, .tooltip = "Delete", .disabled = busy }).clicked) delete_index = index;
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
    c.theme_chosen = state.themeChoice();
    const t = c.theme;
    const idle = state.job == null;

    ui.column(c, .{ .width = .fill, .height = .fill, .background = t.background });
    defer ui.end(c);

    // Content first: the rail's glass reads the pixels painted under it.
    {
        ui.column(c, .{
            .width = .fill,
            .height = .fill,
            .padding = .{ .top = top, .right = 16, .bottom = 16, .left = rail_width + 16 },
            .gap = 12,
        });
        defer ui.end(c);

        if (state.tab == .history) {
            ui.row(c, .{ .width = .fill, .align_items = .center, .padding = .{ .right = row_inset } });
            defer ui.end(c);
            ui.spacer(c);
            const idle_clear = state.rows.len != 0 and idle;
            if (confirm.button(c, &state.confirm_clear, "clear-all", "Clear all", "Click again to clear", !idle_clear)) {
                history.clearHistory(state);
            }
        }
        switch (state.tab) {
            .history => historyView(state, c),
            .settings => settings.page(state, c),
        }
    }

    // The rail last: its glass reads the content painted under it.
    {
        var rail = ui.div(c).absolute().column().w(rail_width).hFull().p(12).pt(rail_top).gap(2);
        rail = if (c.access.reduce_transparency)
            rail.bg(t.surface).border(t.border)
        else
            rail.glass(.{ .style = .sidebar, .blur = 28, .edge_blur = 64, .reflection = 0.16 });
        defer rail.end();

        ui.text(c, "kocr", .{ .size = 15, .weight = .semibold });
        ui.div(c).h(10).end();
        const to_history = navItem(c, "list.bullet", "History", state.tab == .history);
        const to_settings = navItem(c, "gearshape", "Settings", state.tab == .settings);
        if (to_history and state.tab != .history) {
            state.tab = .history;
            state.confirm_clear = false;
            c.changed = true;
        }
        if (to_settings and state.tab != .settings) {
            state.tab = .settings;
            state.confirm_clear = false;
            settings.load(state);
            c.changed = true;
        }
        ui.spacer(c);
        if (navItem(c, "info.circle", "About", false)) about.openAbout(state);
    }

    if (comptime builtin.os.tag == .windows) titleBar(state, c);
}
