//! KDE KGlobalAccel shortcuts over the session bus.
//! Qt key encoding and action registration mirror kocr-rs.

const std = @import("std");

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

const SignalState = struct {
    bindings: []const types.Binding,
    pending: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
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
    return @backingInt(action) + 1;
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
        const code = state.pending.swap(0, .acquire);
        if (code != 0) {
            const action: types.Action = @fromBackingInt(@intCast(code - 1));
            if (!try handler(context, action)) return;
        }
        std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
}

fn onShortcut(state: *SignalState, args: @Tuple(&[_]type{ GStr, GStr, i64 })) void {
    if (!std.mem.eql(u8, args[0].s, component_name)) return;
    for (state.bindings) |binding| {
        if (std.mem.eql(u8, args[1].s, actionInfo(binding.action).name)) {
            state.pending.store(actionCode(binding.action), .release);
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
    const KeySeq = Value.Tuple(struct { []const i32 });
    const KeyList = Value.Array(KeySeq);
    const keys = [_]KeySeq{KeySeq.new(.{key_seq[0..]})};
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
