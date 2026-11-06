//! KDE KGlobalAccel shortcuts over the session bus.
//! Qt key encoding and action registration mirror kocr-rs.

const std = @import("std");

const config = @import("config");
const goose = @import("goose");
const types = @import("core_types");

const GStr = goose.core.value.GStr;
const GPath = goose.core.value.GPath;
const Value = goose.core.value.Value;
const Proxy = goose.proxy.Proxy;

const bus_name = "org.kde.kglobalaccel";
const service_path = "/kglobalaccel";
const component_name = "kocr";
const service_interface = "org.kde.KGlobalAccel";
const component_interface = "org.kde.kglobalaccel.Component";
const set_present_no_autoload: u32 = 2 | 4;

const qt_shift: i32 = 0x0200_0000;
const qt_control: i32 = 0x0400_0000;
const qt_alt: i32 = 0x0800_0000;
const qt_meta: i32 = 0x1000_0000;

pub const KeyboardError = error{
    InvalidShortcut,
    ShortcutUnavailable,
    KeyboardUnavailable,
};

const pending_capacity: u32 = 32;

const SignalState = struct {
    bindings: []const types.Binding,
    pending: [pending_capacity]u8 = undefined,
    pending_head: u32 = 0,
    pending_tail: u32 = 0,
    mutex: std.atomic.Mutex = .unlocked,

    fn push(self: *SignalState, code: u8) bool {
        self.lock();
        defer self.mutex.unlock();
        if (self.pending_tail - self.pending_head >= pending_capacity) return false;
        self.pending[self.pending_tail % pending_capacity] = code;
        self.pending_tail += 1;
        return true;
    }

    fn pop(self: *SignalState) ?u8 {
        self.lock();
        defer self.mutex.unlock();
        if (self.pending_head == self.pending_tail) return null;
        const code = self.pending[self.pending_head % pending_capacity];
        self.pending_head += 1;
        return code;
    }

    fn lock(self: *SignalState) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }
};

const ActionInfo = struct {
    name: [:0]const u8,
    description: [:0]const u8,
};

fn actionInfo(action: types.Action) ActionInfo {
    return switch (action) {
        .copy => .{ .name = "copy", .description = "Capture and copy screenshot" },
        .save => .{ .name = "save", .description = "Capture screenshot and save" },
        .ocr => .{ .name = "capture-ocr", .description = "Capture screenshot and recognize text" },
        .oneline => .{ .name = "capture-ocr-oneline", .description = "Capture screenshot and recognize text in one line" },
    };
}

fn actionCode(action: types.Action) u8 {
    return @as(u8, @intCast(@backingInt(action))) + 1;
}

pub fn listen(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    bindings: []const types.Binding,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    var conn = goose.Connection.initWithBackend(
        allocator,
        .Session,
        io,
        @constCast(environ),
        .poll,
    ) catch return error.KeyboardUnavailable;
    defer conn.close();

    const service = Proxy.init(&conn, bus_name, service_path, service_interface);
    for (bindings) |binding| try register(service, binding);

    var component_result = service.call("getComponent", .{GStr.new(component_name)}) catch
        return error.KeyboardUnavailable;
    defer component_result.deinit();
    const path = try component_result.expect(GPath);
    const component = Proxy.init(&conn, bus_name, path.s, component_interface);

    var state = SignalState{ .bindings = bindings };
    try component.connectSignal(
        @Tuple(&[_]type{ GStr, GStr, i64 }),
        "globalShortcutPressed",
        &state,
        onShortcut,
    );

    while (true) {
        while (conn.dispatch() catch return error.KeyboardUnavailable) {}
        while (state.pop()) |code| {
            const action: types.Action = @fromBackingInt(@intCast(code - 1));
            if (!try handler(context, action)) return;
        }
        std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
}

pub fn listenConfigured(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    context: *anyopaque,
    handler: types.Handler,
) !void {
    var bindings = try loadBindings(allocator, io, environ);
    defer freeBindings(allocator, bindings);

    var conn = goose.Connection.initWithBackend(
        allocator,
        .Session,
        io,
        @constCast(environ),
        .poll,
    ) catch return error.KeyboardUnavailable;
    defer conn.close();

    const service = Proxy.init(&conn, bus_name, service_path, service_interface);
    try registerAll(service, bindings);

    var component_result = service.call("getComponent", .{GStr.new(component_name)}) catch
        return error.KeyboardUnavailable;
    defer component_result.deinit();
    const path = try component_result.expect(GPath);
    const component = Proxy.init(&conn, bus_name, path.s, component_interface);

    var state = SignalState{ .bindings = bindings };
    try component.connectSignal(
        @Tuple(&[_]type{ GStr, GStr, i64 }),
        "globalShortcutPressed",
        &state,
        onShortcut,
    );

    var reload_counter: u8 = 0;
    while (true) {
        while (conn.dispatch() catch return error.KeyboardUnavailable) {}
        while (state.pop()) |code| {
            const action: types.Action = @fromBackingInt(@intCast(code - 1));
            if (!try handler(context, action)) return;
        }
        reload_counter +%= 1;
        if (reload_counter % 20 == 0) {
            const next = loadBindings(allocator, io, environ) catch {
                std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
                continue;
            };
            if (bindingsEqual(bindings, next)) {
                freeBindings(allocator, next);
            } else {
                registerAll(service, next) catch {
                    freeBindings(allocator, next);
                    std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
                    continue;
                };
                freeBindings(allocator, bindings);
                bindings = next;
                state.bindings = bindings;
            }
        }
        std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
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

fn freeBindings(allocator: std.mem.Allocator, bindings: []types.Binding) void {
    for (bindings) |binding| allocator.free(binding.shortcut);
    allocator.free(bindings);
}

fn bindingsEqual(a: []const types.Binding, b: []const types.Binding) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.action != right.action or !std.mem.eql(u8, left.shortcut, right.shortcut)) return false;
    }
    return true;
}

fn registerAll(service: Proxy, bindings: []const types.Binding) !void {
    inline for (.{ types.Action.copy, types.Action.save, types.Action.ocr, types.Action.oneline }) |action| {
        var shortcut: ?[]const u8 = null;
        for (bindings) |binding| {
            if (binding.action == action) {
                shortcut = binding.shortcut;
                break;
            }
        }
        try registerAction(service, action, shortcut);
    }
}

fn registerAction(service: Proxy, action: types.Action, shortcut: ?[]const u8) !void {
    const info = actionInfo(action);
    const action_id = [_]GStr{
        GStr.new(component_name),
        GStr.new(info.name),
        GStr.new("KOCR"),
        GStr.new(info.description),
    };

    var registered = service.call("doRegister", .{action_id[0..]}) catch
        return error.KeyboardUnavailable;
    registered.deinit();

    const KeyStruct = struct { keys: []const i32 };
    const KeySeq = Value.Struct(KeyStruct);
    const KeyList = Value.Array(KeySeq);
    var key_storage: [1]KeySeq = undefined;
    var keys_slice: []const KeySeq = &.{};
    if (shortcut) |value| {
        const key = try parseShortcut(value);
        const key_seq = [_]i32{ key, 0, 0, 0 };
        key_storage[0] = KeySeq.new(.{ .keys = key_seq[0..] });
        keys_slice = key_storage[0..];
    }
    const assigned = KeyList.new(keys_slice);

    var result = service.call("setShortcutKeys", .{
        action_id[0..],
        assigned,
        set_present_no_autoload,
    }) catch return error.ShortcutUnavailable;
    result.deinit();
}

fn onShortcut(state: *SignalState, args: @Tuple(&[_]type{ GStr, GStr, i64 })) void {
    if (!std.mem.eql(u8, args[0].s, component_name)) return;
    for (state.bindings) |binding| {
        if (std.mem.eql(u8, args[1].s, actionInfo(binding.action).name)) {
            _ = state.push(actionCode(binding.action));
            return;
        }
    }
}

fn register(service: Proxy, binding: types.Binding) !void {
    const info = actionInfo(binding.action);
    const action_id = [_]GStr{
        GStr.new(component_name),
        GStr.new(info.name),
        GStr.new("KOCR"),
        GStr.new(info.description),
    };

    var registered = service.call("doRegister", .{action_id[0..]}) catch
        return error.KeyboardUnavailable;
    registered.deinit();

    const key = try parseShortcut(binding.shortcut);
    const key_seq = [_]i32{ key, 0, 0, 0 };
    const KeyStruct = struct { keys: []const i32 };
    const KeySeq = Value.Struct(KeyStruct);
    const KeyList = Value.Array(KeySeq);
    const keys = [_]KeySeq{KeySeq.new(.{ .keys = key_seq[0..] })};
    const assigned = KeyList.new(keys[0..]);

    var result = service.call("setShortcutKeys", .{
        action_id[0..],
        assigned,
        set_present_no_autoload,
    }) catch return error.ShortcutUnavailable;
    result.deinit();
}

fn parseShortcut(shortcut: []const u8) !i32 {
    if (shortcut.len == 0) return error.InvalidShortcut;
    var key: ?i32 = null;
    var modifiers: i32 = 0;
    var it = std.mem.splitScalar(u8, shortcut, '+');
    while (it.next()) |part| {
        const token = std.mem.trim(u8, part, &std.ascii.whitespace);
        if (token.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(token, "ctrl") or std.ascii.eqlIgnoreCase(token, "control")) {
            modifiers |= qt_control;
        } else if (std.ascii.eqlIgnoreCase(token, "alt")) {
            modifiers |= qt_alt;
        } else if (std.ascii.eqlIgnoreCase(token, "shift")) {
            modifiers |= qt_shift;
        } else if (std.ascii.eqlIgnoreCase(token, "meta") or
            std.ascii.eqlIgnoreCase(token, "super") or
            std.ascii.eqlIgnoreCase(token, "mod"))
        {
            modifiers |= qt_meta;
        } else {
            key = try parseKey(token);
        }
    }
    return (key orelse return error.InvalidShortcut) | modifiers;
}

fn parseKey(token: []const u8) !i32 {
    if (token.len == 1) return std.ascii.toUpper(token[0]);
    if (token.len >= 2 and (token[0] == 'F' or token[0] == 'f')) {
        const number = std.fmt.parseInt(u8, token[1..], 10) catch return error.InvalidShortcut;
        if (number >= 1 and number <= 35) return 0x0100_0030 + @as(i32, number) - 1;
    }
    const keys = .{
        .{ "escape", @as(i32, 0x0100_0000) },
        .{ "tab", 0x0100_0001 },
        .{ "backspace", 0x0100_0003 },
        .{ "return", 0x0100_0004 },
        .{ "enter", 0x0100_0005 },
        .{ "insert", 0x0100_0006 },
        .{ "delete", 0x0100_0007 },
        .{ "home", 0x0100_0010 },
        .{ "end", 0x0100_0011 },
        .{ "left", 0x0100_0012 },
        .{ "up", 0x0100_0013 },
        .{ "right", 0x0100_0014 },
        .{ "down", 0x0100_0015 },
        .{ "pageup", 0x0100_0016 },
        .{ "pagedown", 0x0100_0017 },
        .{ "space", 0x20 },
        .{ "apostrophe", '\'' },
        .{ "comma", ',' },
        .{ "minus", '-' },
        .{ "period", '.' },
        .{ "slash", '/' },
        .{ "semicolon", ';' },
        .{ "equal", '=' },
        .{ "bracketleft", '[' },
        .{ "backslash", '\\' },
        .{ "bracketright", ']' },
        .{ "grave", '`' },
    };
    inline for (keys) |entry| {
        if (std.ascii.eqlIgnoreCase(token, entry[0])) return entry[1];
    }
    return error.InvalidShortcut;
}

test "parses KDE shortcuts" {
    try std.testing.expectEqual(qt_alt | '1', try parseShortcut("Alt+1"));
    try std.testing.expectEqual(
        qt_meta | qt_shift | '/',
        try parseShortcut("Mod+Shift+Slash"),
    );
    try std.testing.expectError(error.InvalidShortcut, parseShortcut("Hyper+X"));
}

test "encodes all daemon actions" {
    inline for (.{ types.Action.copy, types.Action.save, types.Action.ocr, types.Action.oneline }) |action| {
        try std.testing.expect(actionCode(action) != 0);
        try std.testing.expectEqual(action, @as(types.Action, @fromBackingInt(@intCast(actionCode(action) - 1))));
    }
}
