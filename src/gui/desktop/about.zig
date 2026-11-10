//! The About window: what kocr is, and where it lives.

const std = @import("std");

const nui = @import("nanoui");

const state_mod = @import("state.zig");
const windows = @import("windows.zig");

const ui = nui.ui;
const kit = nui.kit;
const State = state_mod.State;

const version = @import("build_options").version;
const repository = "https://github.com/KercyDing/kocr";
const summary = "Offline OCR for images and screen captures.";
const privacy = "No account, no server, no uploads.";

fn closed(context: *anyopaque, window: *nui.Window) void {
    _ = window;
    const state: *State = @ptrCast(@alignCast(context));
    state.about_window = null;
}

pub fn openAbout(state: *State) void {
    if (state.about_window) |window| {
        window.focus();
        return;
    }
    const app = state.app orelse return;
    const window = app.newWindow(.{
        .title = "About kocr",
        .width = 420,
        .height = 216,
        .min_width = 380,
        .min_height = 200,
        .icon = windows.windowIcon(),
        .content = .{ .view = .init(state, view) },
        .on_close = .{ .ctx = state, .func = closed },
    }) catch return;
    state.about_window = window;
}

fn view(state: *State, c: *ui.Context) void {
    c.theme_chosen = state.themeChoice();
    const t = c.theme;
    ui.column(c, .{ .width = .fill, .height = .fill, .padding = .all(20), .gap = 10, .background = t.background });
    defer ui.end(c);

    ui.text(c, "kocr", .{ .size = 20, .weight = .semibold });
    ui.text(c, c.print("Version {s} · MIT License", .{version}), .{ .size = 12, .color = t.muted });
    ui.text(c, summary, .{ .size = 13, .wrap = true });
    ui.text(c, privacy, .{ .size = 13, .wrap = true });
    ui.spacer(c);
    if (kit.button(c, repository, .{ .variant = .link }).clicked) _ = nui.shell.openUrl(repository);
}
