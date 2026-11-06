//! Global shortcuts via RegisterHotKey, driven by a hidden message window.

const std = @import("std");

const config = @import("config");
const types = @import("core_types");
const win32 = @import("win32");

const user32 = win32.user32;
const kernel32 = win32.kernel32;
const wm = win32.ui.windows_and_messaging;
const keys = win32.ui.input.keyboard_and_mouse;
const foundation = win32.foundation;
const class_name = win32.zig.L("kocr-hotkey-window");

const MOD_ALT: u32 = 0x0001;
const MOD_CONTROL: u32 = 0x0002;
const MOD_SHIFT: u32 = 0x0004;
const MOD_WIN: u32 = 0x0008;

var listener: ?*Listener = null;

pub const KeyboardError = error{
    InvalidShortcut,
    ShortcutUnavailable,
    KeyboardUnavailable,
};

pub const Shortcut = struct {
    modifiers: u32,
    vk: u32,
};

const Listener = struct {
    hwnd: foundation.HWND,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    bindings: []const types.Binding,
    owned: bool,
    reload_from_config: bool,
    context: *anyopaque,
    handler: types.Handler,
    registered: usize = 0,

    fn unregisterAll(self: *Listener) void {
        var id: u32 = 1;
        while (id <= self.registered) : (id += 1) _ = user32.UnregisterHotKey(self.hwnd, @intCast(id));
        self.registered = 0;
    }

    fn registerAll(self: *Listener) !void {
        for (self.bindings, 0..) |binding, index| {
            const shortcut = try parse(binding.shortcut);
            const id: i32 = @intCast(index + 1);
            if (user32.RegisterHotKey(self.hwnd, id, modifiers(shortcut.modifiers), shortcut.vk) == 0)
                return KeyboardError.ShortcutUnavailable;
            self.registered += 1;
        }
    }
};

fn modifiers(bits: u32) keys.HOT_KEY_MODIFIERS {
    var value: keys.HOT_KEY_MODIFIERS = .{};
    value.ALT = @intFromBool(bits & MOD_ALT != 0);
    value.CONTROL = @intFromBool(bits & MOD_CONTROL != 0);
    value.SHIFT = @intFromBool(bits & MOD_SHIFT != 0);
    value.WIN = @intFromBool(bits & MOD_WIN != 0);
    return value;
}

fn hotkeyProc(hwnd: foundation.HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (message) {
        wm.WM_HOTKEY => {
            const state = listener orelse return 0;
            const id: usize = @intCast(wparam);
            if (id == 0 or id > state.bindings.len) return 0;
            const action = state.bindings[id - 1].action;
            const keep = state.handler(state.context, action) catch false;
            if (!keep) user32.PostQuitMessage(0);
            return 0;
        },
        wm.WM_TIMER => {
            const state = listener orelse return 0;
            if (state.reload_from_config) reload(state);
            return 0;
        },
        wm.WM_DESTROY => {
            user32.PostQuitMessage(0);
            return 0;
        },
        else => return user32.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn reload(state: *Listener) void {
    const next = loadBindings(state.allocator, state.io, state.environ) catch return;
    if (sameBindings(state.bindings, next)) {
        freeBindings(state.allocator, next);
        return;
    }
    state.unregisterAll();
    freeBindings(state.allocator, state.bindings);
    state.bindings = next;
    state.registerAll() catch {};
}

fn sameBindings(left: []const types.Binding, right: []const types.Binding) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.action != b.action or !std.mem.eql(u8, a.shortcut, b.shortcut)) return false;
    }
    return true;
}

fn createWindow() !foundation.HWND {
    const instance = kernel32.GetModuleHandleW(null);
    var window_class: wm.WNDCLASSEXW = std.mem.zeroes(wm.WNDCLASSEXW);
    window_class.cbSize = @sizeOf(wm.WNDCLASSEXW);
    window_class.lpfnWndProc = &hotkeyProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name;
    _ = user32.RegisterClassExW(&window_class);
    return user32.CreateWindowExW(
        .{},
        class_name,
        class_name,
        .{},
        0,
        0,
        0,
        0,
        wm.HWND_MESSAGE,
        null,
        instance,
        null,
    ) orelse KeyboardError.KeyboardUnavailable;
}

fn run(state: *Listener) !void {
    listener = state;
    defer listener = null;

    state.hwnd = try createWindow();
    defer _ = user32.DestroyWindow(state.hwnd);
    try state.registerAll();
    defer state.unregisterAll();

    if (state.reload_from_config) _ = user32.SetTimer(state.hwnd, 1, 500, null);

    var message: wm.MSG = undefined;
    while (user32.GetMessageW(&message, null, 0, 0) > 0) {
        _ = user32.TranslateMessage(&message);
        _ = user32.DispatchMessageW(&message);
    }
}

pub fn listen(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    bindings: []const types.Binding,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    var state = Listener{
        .hwnd = undefined,
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .bindings = bindings,
        .owned = false,
        .reload_from_config = false,
        .context = context,
        .handler = handler,
    };
    try run(&state);
}

pub fn listenConfigured(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    const bindings = try loadBindings(allocator, io, environ);
    var state = Listener{
        .hwnd = undefined,
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .bindings = bindings,
        .owned = true,
        .reload_from_config = true,
        .context = context,
        .handler = handler,
    };
    defer freeBindings(allocator, state.bindings);
    try run(&state);
}

fn loadBindings(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) ![]types.Binding {
    var parsed = try config.load(allocator, io, environ);
    defer parsed.deinit();
    var list: std.ArrayList(types.Binding) = .empty;
    errdefer {
        for (list.items) |binding| allocator.free(binding.shortcut);
        list.deinit(allocator);
    }
    try appendBinding(allocator, &list, .copy, parsed.value.shortcuts.copy);
    try appendBinding(allocator, &list, .save, parsed.value.shortcuts.save);
    try appendBinding(allocator, &list, .ocr, parsed.value.shortcuts.ocr);
    try appendBinding(allocator, &list, .oneline, parsed.value.shortcuts.oneline);
    return list.toOwnedSlice(allocator);
}

fn appendBinding(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(types.Binding),
    action: types.Action,
    shortcut: ?[]const u8,
) !void {
    const value = shortcut orelse return;
    if (value.len == 0) return;
    try list.append(allocator, .{
        .action = action,
        .shortcut = try allocator.dupe(u8, value),
    });
}

fn freeBindings(allocator: std.mem.Allocator, bindings: []const types.Binding) void {
    for (bindings) |binding| allocator.free(binding.shortcut);
    allocator.free(bindings);
}

/// Parses names such as `Ctrl+Alt+C` or `Mod+Shift+Slash`.
pub fn parse(text: []const u8) !Shortcut {
    if (text.len == 0) return KeyboardError.InvalidShortcut;
    var result = Shortcut{ .modifiers = 0, .vk = 0 };
    var have_key = false;
    var it = std.mem.splitScalar(u8, text, '+');
    while (it.next()) |part| {
        const token = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (token.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(token, "ctrl") or std.ascii.eqlIgnoreCase(token, "control")) {
            result.modifiers |= MOD_CONTROL;
        } else if (std.ascii.eqlIgnoreCase(token, "alt")) {
            result.modifiers |= MOD_ALT;
        } else if (std.ascii.eqlIgnoreCase(token, "shift")) {
            result.modifiers |= MOD_SHIFT;
        } else if (std.ascii.eqlIgnoreCase(token, "meta") or
            std.ascii.eqlIgnoreCase(token, "super") or
            std.ascii.eqlIgnoreCase(token, "win") or
            std.ascii.eqlIgnoreCase(token, "mod"))
        {
            result.modifiers |= MOD_WIN;
        } else {
            if (have_key) return KeyboardError.InvalidShortcut;
            result.vk = try parseKey(token);
            have_key = true;
        }
    }
    if (!have_key) return KeyboardError.InvalidShortcut;
    return result;
}

fn parseKey(token: []const u8) !u32 {
    if (token.len == 1) {
        const upper = std.ascii.toUpper(token[0]);
        if ((upper >= 'A' and upper <= 'Z') or (upper >= '0' and upper <= '9')) return upper;
        return KeyboardError.InvalidShortcut;
    }
    if (token.len >= 2 and (token[0] == 'F' or token[0] == 'f')) {
        const number = std.fmt.parseInt(u8, token[1..], 10) catch return KeyboardError.InvalidShortcut;
        if (number >= 1 and number <= 24) return 0x70 + @as(u32, number) - 1;
        return KeyboardError.InvalidShortcut;
    }
    const named = .{
        .{ "escape", @as(u32, 0x1B) },
        .{ "esc", 0x1B },
        .{ "tab", 0x09 },
        .{ "backspace", 0x08 },
        .{ "return", 0x0D },
        .{ "enter", 0x0D },
        .{ "insert", 0x2D },
        .{ "delete", 0x2E },
        .{ "home", 0x24 },
        .{ "end", 0x23 },
        .{ "left", 0x25 },
        .{ "up", 0x26 },
        .{ "right", 0x27 },
        .{ "down", 0x28 },
        .{ "pageup", 0x21 },
        .{ "pagedown", 0x22 },
        .{ "space", 0x20 },
        .{ "print", 0x2C },
        .{ "printscreen", 0x2C },
        .{ "pause", 0x13 },
        .{ "capslock", 0x14 },
        .{ "numlock", 0x90 },
        .{ "scrolllock", 0x91 },
        .{ "apostrophe", 0xDE },
        .{ "comma", 0xBC },
        .{ "minus", 0xBD },
        .{ "period", 0xBE },
        .{ "slash", 0xBF },
        .{ "semicolon", 0xBA },
        .{ "equal", 0xBB },
        .{ "bracketleft", 0xDB },
        .{ "backslash", 0xDC },
        .{ "bracketright", 0xDD },
        .{ "grave", 0xC0 },
    };
    inline for (named) |entry| {
        if (std.ascii.eqlIgnoreCase(token, entry[0])) return entry[1];
    }
    return KeyboardError.InvalidShortcut;
}

/// Name for `vk`, or null when the key has no portable name.
pub fn keyName(vk: u32) ?[]const u8 {
    if (vk >= 'A' and vk <= 'Z') return null;
    if (vk >= '0' and vk <= '9') return null;
    if (vk >= 0x70 and vk <= 0x87) return null;
    return switch (vk) {
        0x1B => "Esc",
        0x09 => "Tab",
        0x08 => "Backspace",
        0x0D => "Enter",
        0x2D => "Insert",
        0x2E => "Delete",
        0x24 => "Home",
        0x23 => "End",
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        0x21 => "PageUp",
        0x22 => "PageDown",
        0x20 => "Space",
        0x2C => "Print",
        0x13 => "Pause",
        0x14 => "CapsLock",
        0x90 => "NumLock",
        0x91 => "ScrollLock",
        0xDE => "Apostrophe",
        0xBC => "Comma",
        0xBD => "Minus",
        0xBE => "Period",
        0xBF => "Slash",
        0xBA => "Semicolon",
        0xBB => "Equal",
        0xDB => "BracketLeft",
        0xDC => "Backslash",
        0xDD => "BracketRight",
        0xC0 => "Grave",
        else => null,
    };
}

/// Formats `shortcut` into `buffer`, mirroring `parse`.
pub fn format(buffer: []u8, shortcut: Shortcut) []const u8 {
    var key_buffer: [16]u8 = undefined;
    const key = if (shortcut.vk >= 'A' and shortcut.vk <= 'Z' or shortcut.vk >= '0' and shortcut.vk <= '9')
        std.fmt.bufPrint(&key_buffer, "{c}", .{@as(u8, @intCast(shortcut.vk))}) catch return buffer[0..0]
    else if (shortcut.vk >= 0x70 and shortcut.vk <= 0x87)
        std.fmt.bufPrint(&key_buffer, "F{d}", .{shortcut.vk - 0x70 + 1}) catch return buffer[0..0]
    else
        keyName(shortcut.vk) orelse return buffer[0..0];
    return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}{s}", .{
        if (shortcut.modifiers & MOD_CONTROL != 0) "Ctrl+" else "",
        if (shortcut.modifiers & MOD_ALT != 0) "Alt+" else "",
        if (shortcut.modifiers & MOD_SHIFT != 0) "Shift+" else "",
        if (shortcut.modifiers & MOD_WIN != 0) "Win+" else "",
        key,
    }) catch buffer[0..0];
}

/// Translates a key press into the modifier bits consumed by `parse`.
pub fn modifiersFromState(ctrl: bool, alt: bool, shift: bool, win: bool) u32 {
    return (if (ctrl) MOD_CONTROL else 0) |
        (if (alt) MOD_ALT else 0) |
        (if (shift) MOD_SHIFT else 0) |
        (if (win) MOD_WIN else 0);
}

test "parses windows shortcuts" {
    const ctrl_alt_c = try parse("Ctrl+Alt+C");
    try std.testing.expectEqual(MOD_CONTROL | MOD_ALT, ctrl_alt_c.modifiers);
    try std.testing.expectEqual(@as(u32, 'C'), ctrl_alt_c.vk);
    try std.testing.expectError(KeyboardError.InvalidShortcut, parse("Hyper+X"));
}

test "formats windows shortcuts" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+F5", format(&buffer, .{ .modifiers = MOD_CONTROL | MOD_SHIFT, .vk = 0x74 }));
    try std.testing.expectEqualStrings("Win+Space", format(&buffer, .{ .modifiers = MOD_WIN, .vk = 0x20 }));
}

comptime {
    _ = keys;
}
