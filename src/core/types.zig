pub const Action = enum {
    copy,
    save,
    ocr,
    oneline,
};

pub const Binding = struct {
    action: Action,
    shortcut: []const u8,
};

pub const Handler = *const fn (context: *anyopaque, action: Action) anyerror!bool;
