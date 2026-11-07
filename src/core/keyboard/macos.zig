//! macOS global shortcuts through Carbon hot keys. Carbon hot keys, unlike
//! event taps, need no accessibility permission. Virtual key codes follow
//! Carbon's `Events.h` table.

const std = @import("std");

const config = @import("../config.zig");
const types = @import("../types.zig");

const cmd_key: u32 = 1 << 8;
const shift_key: u32 = 1 << 9;
const option_key: u32 = 1 << 11;
const control_key: u32 = 1 << 12;

const signature: u32 = 0x4B4F4352; // 'KOCR'
const event_class_keyboard: u32 = 0x6B657962; // 'keyb'
const event_hot_key_pressed: u32 = 5;
const event_param_direct_object: u32 = 0x2D2D2D2D; // '----'
const type_event_hot_key_id: u32 = 0x686B6964; // 'hkid'
const event_not_handled: i32 = -9874;
const event_loop_timed_out: i32 = -9875;

const carbon = struct {
    const OSStatus = i32;

    const EventRef = *opaque {};
    const EventTargetRef = *opaque {};
    const EventHandlerRef = *opaque {};
    const EventHandlerCallRef = *opaque {};
    const EventHotKeyRef = *opaque {};

    const EventTypeSpec = extern struct {
        event_class: u32,
        event_kind: u32,
    };

    const EventHotKeyID = extern struct {
        signature: u32,
        id: u32,
    };

    extern fn GetApplicationEventTarget() ?EventTargetRef;
    extern fn InstallEventHandler(
        target: EventTargetRef,
        handler: *const fn (EventHandlerCallRef, EventRef, ?*anyopaque) callconv(.c) OSStatus,
        num_types: usize,
        types: *const EventTypeSpec,
        user_data: ?*anyopaque,
        out_ref: *?EventHandlerRef,
    ) OSStatus;
    extern fn RemoveEventHandler(ref: EventHandlerRef) OSStatus;
    extern fn RegisterEventHotKey(
        key_code: u32,
        modifiers: u32,
        hot_key_id: EventHotKeyID,
        target: EventTargetRef,
        options: u32,
        out_ref: *?EventHotKeyRef,
    ) OSStatus;
    extern fn UnregisterEventHotKey(ref: EventHotKeyRef) OSStatus;
    extern fn GetEventParameter(
        event: EventRef,
        name: u32,
        desired_type: u32,
        actual_type: ?*u32,
        buffer_size: usize,
        actual_size: ?*usize,
        data: ?*anyopaque,
    ) OSStatus;
    extern fn ReceiveNextEvent(
        num_types: u32,
        types: *const EventTypeSpec,
        timeout: f64,
        wake_up: u8,
        out_event: *?EventRef,
    ) OSStatus;
    extern fn SendEventToEventTarget(event: EventRef, target: EventTargetRef) OSStatus;
    extern fn ReleaseEvent(event: EventRef) OSStatus;
};

pub const KeyboardError = error{
    InvalidShortcut,
    ShortcutUnavailable,
    KeyboardUnavailable,
};

pub const Shortcut = struct {
    modifiers: u32,
    key: u32,
};

const Listener = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    bindings: []const types.Binding,
    owned: bool,
    reload_from_config: bool,
    context: *anyopaque,
    handler: types.Handler,
    target: ?carbon.EventTargetRef = null,
    handler_ref: ?carbon.EventHandlerRef = null,
    hot_keys: std.ArrayList(?carbon.EventHotKeyRef) = .empty,
    stop: bool = false,

    fn unregisterAll(self: *Listener) void {
        for (self.hot_keys.items) |ref| {
            if (ref) |value| _ = carbon.UnregisterEventHotKey(value);
        }
        self.hot_keys.clearRetainingCapacity();
    }

    fn registerAll(self: *Listener) !void {
        self.unregisterAll();
        for (self.bindings) |binding| {
            const shortcut = try parse(binding.shortcut);
            var ref: ?carbon.EventHotKeyRef = null;
            const status = carbon.RegisterEventHotKey(
                shortcut.key,
                shortcut.modifiers,
                .{ .signature = signature, .id = @intCast(self.hot_keys.items.len + 1) },
                self.target orelse return error.KeyboardUnavailable,
                0,
                &ref,
            );
            if (status != 0) return KeyboardError.ShortcutUnavailable;
            try self.hot_keys.append(self.allocator, ref);
        }
    }
};

var listener: ?*Listener = null;

fn onHotKey(
    _: carbon.EventHandlerCallRef,
    event: carbon.EventRef,
    _: ?*anyopaque,
) callconv(.c) carbon.OSStatus {
    const state = listener orelse return event_not_handled;
    var id: carbon.EventHotKeyID = undefined;
    const status = carbon.GetEventParameter(
        event,
        event_param_direct_object,
        type_event_hot_key_id,
        null,
        @sizeOf(carbon.EventHotKeyID),
        null,
        &id,
    );
    if (status != 0 or id.signature != signature) return event_not_handled;
    if (id.id == 0 or id.id > state.bindings.len) return event_not_handled;
    const keep = state.handler(state.context, state.bindings[id.id - 1].action) catch false;
    if (!keep) state.stop = true;
    return 0;
}

fn install(self: *Listener) !void {
    self.target = carbon.GetApplicationEventTarget() orelse
        return error.KeyboardUnavailable;
    var event_type = carbon.EventTypeSpec{
        .event_class = event_class_keyboard,
        .event_kind = event_hot_key_pressed,
    };
    const status = carbon.InstallEventHandler(
        self.target.?,
        onHotKey,
        1,
        &event_type,
        null,
        &self.handler_ref,
    );
    if (status != 0) return error.KeyboardUnavailable;
}

fn uninstall(self: *Listener) void {
    if (self.handler_ref) |ref| _ = carbon.RemoveEventHandler(ref);
    self.handler_ref = null;
}

fn reload(state: *Listener) void {
    const next = loadBindings(state.allocator, state.io, state.environ) catch return;
    if (sameBindings(state.bindings, next)) {
        freeBindings(state.allocator, next);
        return;
    }
    if (state.owned) freeBindings(state.allocator, state.bindings);
    state.bindings = next;
    state.owned = true;
    state.registerAll() catch {};
}

fn run(state: *Listener) !void {
    listener = state;
    defer listener = null;

    try install(state);
    defer uninstall(state);
    defer state.unregisterAll();
    try state.registerAll();

    var event_type = carbon.EventTypeSpec{
        .event_class = event_class_keyboard,
        .event_kind = event_hot_key_pressed,
    };
    var reload_counter: u8 = 0;
    while (!state.stop) {
        var event: ?carbon.EventRef = null;
        const status = carbon.ReceiveNextEvent(1, &event_type, 0.05, 1, &event);
        if (status == 0) {
            _ = carbon.SendEventToEventTarget(event.?, state.target.?);
            _ = carbon.ReleaseEvent(event.?);
        } else if (status != event_loop_timed_out) {
            return error.KeyboardUnavailable;
        }
        if (state.reload_from_config) {
            reload_counter +%= 1;
            if (reload_counter % 10 == 0) reload(state);
        }
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
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .bindings = bindings,
        .owned = false,
        .reload_from_config = false,
        .context = context,
        .handler = handler,
    };
    defer state.hot_keys.deinit(allocator);
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
        .allocator = allocator,
        .io = io,
        .environ = environ,
        .bindings = bindings,
        .owned = true,
        .reload_from_config = true,
        .context = context,
        .handler = handler,
    };
    defer state.hot_keys.deinit(allocator);
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

fn sameBindings(left: []const types.Binding, right: []const types.Binding) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a.action != b.action or !std.mem.eql(u8, a.shortcut, b.shortcut)) return false;
    }
    return true;
}

/// Parses names such as `Meta+Shift+C` or `Alt+F5`.
pub fn parse(text: []const u8) !Shortcut {
    if (text.len == 0) return error.InvalidShortcut;
    var result = Shortcut{ .modifiers = 0, .key = 0 };
    var have_key = false;
    var it = std.mem.splitScalar(u8, text, '+');
    while (it.next()) |part| {
        const token = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (token.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(token, "ctrl") or std.ascii.eqlIgnoreCase(token, "control")) {
            result.modifiers |= control_key;
        } else if (std.ascii.eqlIgnoreCase(token, "alt") or
            std.ascii.eqlIgnoreCase(token, "option") or
            std.ascii.eqlIgnoreCase(token, "opt"))
        {
            result.modifiers |= option_key;
        } else if (std.ascii.eqlIgnoreCase(token, "shift")) {
            result.modifiers |= shift_key;
        } else if (std.ascii.eqlIgnoreCase(token, "meta") or
            std.ascii.eqlIgnoreCase(token, "super") or
            std.ascii.eqlIgnoreCase(token, "cmd") or
            std.ascii.eqlIgnoreCase(token, "command") or
            std.ascii.eqlIgnoreCase(token, "mod"))
        {
            result.modifiers |= cmd_key;
        } else {
            if (have_key) return error.InvalidShortcut;
            result.key = try parseKey(token);
            have_key = true;
        }
    }
    if (!have_key) return error.InvalidShortcut;
    return result;
}

fn parseKey(token: []const u8) !u32 {
    if (token.len == 1) {
        return switch (std.ascii.toUpper(token[0])) {
            'A' => 0x00,
            'S' => 0x01,
            'D' => 0x02,
            'F' => 0x03,
            'H' => 0x04,
            'G' => 0x05,
            'Z' => 0x06,
            'X' => 0x07,
            'C' => 0x08,
            'V' => 0x09,
            'B' => 0x0B,
            'Q' => 0x0C,
            'W' => 0x0D,
            'E' => 0x0E,
            'R' => 0x0F,
            'Y' => 0x10,
            'T' => 0x11,
            'O' => 0x1F,
            'U' => 0x20,
            'I' => 0x22,
            'P' => 0x23,
            'L' => 0x25,
            'J' => 0x26,
            'K' => 0x28,
            'N' => 0x2D,
            'M' => 0x2E,
            '1' => 0x12,
            '2' => 0x13,
            '3' => 0x14,
            '4' => 0x15,
            '6' => 0x16,
            '5' => 0x17,
            '9' => 0x19,
            '7' => 0x1A,
            '8' => 0x1C,
            '0' => 0x1D,
            '\'' => 0x27,
            ',' => 0x2B,
            '-' => 0x1B,
            '.' => 0x2F,
            '/' => 0x2C,
            ';' => 0x29,
            '=' => 0x18,
            '[' => 0x21,
            '\\' => 0x2A,
            ']' => 0x1E,
            '`' => 0x32,
            else => error.InvalidShortcut,
        };
    }
    if (token[0] == 'F' or token[0] == 'f') {
        const number = std.fmt.parseInt(u8, token[1..], 10) catch
            return error.InvalidShortcut;
        return switch (number) {
            1 => 0x7A,
            2 => 0x78,
            3 => 0x63,
            4 => 0x76,
            5 => 0x60,
            6 => 0x61,
            7 => 0x62,
            8 => 0x64,
            9 => 0x65,
            10 => 0x6D,
            11 => 0x67,
            12 => 0x6F,
            13 => 0x69,
            14 => 0x6B,
            15 => 0x71,
            16 => 0x6A,
            17 => 0x40,
            18 => 0x4F,
            19 => 0x50,
            20 => 0x5A,
            else => error.InvalidShortcut,
        };
    }
    const named = .{
        .{ "escape", @as(u32, 0x35) },
        .{ "esc", 0x35 },
        .{ "tab", 0x30 },
        .{ "backspace", 0x33 },
        .{ "return", 0x24 },
        .{ "enter", 0x24 },
        .{ "insert", 0x72 },
        .{ "delete", 0x75 },
        .{ "home", 0x73 },
        .{ "end", 0x77 },
        .{ "left", 0x7B },
        .{ "right", 0x7C },
        .{ "down", 0x7D },
        .{ "up", 0x7E },
        .{ "pageup", 0x74 },
        .{ "pagedown", 0x79 },
        .{ "space", 0x31 },
        .{ "apostrophe", 0x27 },
        .{ "comma", 0x2B },
        .{ "minus", 0x1B },
        .{ "period", 0x2F },
        .{ "slash", 0x2C },
        .{ "semicolon", 0x29 },
        .{ "equal", 0x18 },
        .{ "bracketleft", 0x21 },
        .{ "backslash", 0x2A },
        .{ "bracketright", 0x1E },
        .{ "grave", 0x32 },
    };
    inline for (named) |entry| {
        if (std.ascii.eqlIgnoreCase(token, entry[0])) return entry[1];
    }
    return error.InvalidShortcut;
}

test "parses macos shortcuts" {
    const copy = try parse("Meta+Shift+C");
    try std.testing.expectEqual(cmd_key | shift_key, copy.modifiers);
    try std.testing.expectEqual(@as(u32, 0x08), copy.key);

    const ocr = try parse("Alt+Option+F5");
    try std.testing.expectEqual(option_key, ocr.modifiers);
    try std.testing.expectEqual(@as(u32, 0x60), ocr.key);

    try std.testing.expectError(error.InvalidShortcut, parse("Meta"));
    try std.testing.expectError(error.InvalidShortcut, parse("Hyper+X"));
    try std.testing.expectError(error.InvalidShortcut, parse("Meta+A+B"));
}
