//! State shared by the main and settings windows.

const std = @import("std");

const core = @import("core");
const nui = @import("nanoui");

const jobs = @import("jobs.zig");

const Job = jobs.Job;

pub const Row = struct {
    time: []u8,
    label: []u8,
    detail: ?[]u8,
    image: ?[]u8,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    main_window: ?*nui.Window = null,
    settings_window: ?*nui.Window = null,
    app: ?*nui.App = null,
    daemon_running: bool = false,
    profile_index: usize = 0,
    installed: bool = false,
    job: ?*Job = null,
    selected: ?usize = null,
    autostart: bool = false,
    main_status: []u8,
    settings_status: []u8,
    records: []core.history.Record = &.{},
    rows: []Row = &.{},
    history_revision: ?core.history.Revision = null,
    dark: ?bool = null,
    title_bar_dark: ?bool = null,
    shortcuts: [4]?[]u8 = .{ null, null, null, null },

    pub fn init(process_init: std.process.Init) !State {
        const status = try process_init.gpa.dupe(u8, "Ready");
        errdefer process_init.gpa.free(status);
        const settings_status = try process_init.gpa.dupe(u8, "Ready");
        return .{
            .allocator = process_init.gpa,
            .io = process_init.io,
            .environ = process_init.environ_map,
            .main_status = status,
            .settings_status = settings_status,
        };
    }

    pub fn deinit(self: *State) void {
        self.freeHistory();
        self.allocator.free(self.main_status);
        self.allocator.free(self.settings_status);
        for (&self.shortcuts) |*shortcut| {
            if (shortcut.*) |text| self.allocator.free(text);
            shortcut.* = null;
        }
        if (self.job) |job| {
            if (job.thread) |thread| thread.join();
            self.job = null;
            job.deinit();
        }
    }

    pub fn setMainStatus(self: *State, text: []const u8) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(self.main_status);
        self.main_status = copy;
    }

    pub fn setSettingsStatus(self: *State, text: []const u8) void {
        const copy = self.allocator.dupe(u8, text) catch return;
        self.allocator.free(self.settings_status);
        self.settings_status = copy;
    }

    pub fn freeHistory(self: *State) void {
        core.history.freeRecords(self.allocator, self.records);
        self.records = &.{};
        for (self.rows) |row| {
            self.allocator.free(row.time);
            self.allocator.free(row.label);
            if (row.detail) |text| self.allocator.free(text);
            if (row.image) |bytes| self.allocator.free(bytes);
        }
        if (self.rows.len != 0) self.allocator.free(self.rows);
        self.rows = &.{};
        self.selected = null;
    }

    pub fn redraw(self: *State) void {
        if (self.main_window) |window| window.redraw();
        if (self.settings_window) |window| window.redraw();
    }
};
