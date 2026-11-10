//! Main-window history: loading, polling, and entry actions.

const std = @import("std");

const core = @import("core");

const state_mod = @import("state.zig");

const State = state_mod.State;
const Row = state_mod.Row;

/// Pictures are kept this large for the list: the window draws 56×48 rows and
/// a 368-wide preview from them, so a screenful each would be waste.
const preview_side = 512;

var stamp_buffer: [32]u8 = undefined;

/// Rebuilds records and rows; a row whose picture is already loaded keeps it.
pub fn loadHistory(state: *State) void {
    var selected_id: ?i64 = null;
    if (state.selected) |index| {
        if (index < state.records.len) selected_id = state.records[index].id;
    }
    const records = core.history.recent(state.io, state.allocator, state.environ, core.history.kept) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setMainStatus(std.fmt.bufPrint(&buffer, "History error: {s}", .{@errorName(err)}) catch "History error");
        return;
    };
    const rows = state.allocator.alloc(Row, records.len) catch {
        core.history.freeRecords(state.allocator, records);
        return;
    };
    for (records, 0..) |record, index| {
        var stamp_scratch: [64]u8 = undefined;
        const stamp = std.fmt.bufPrint(&stamp_scratch, "{s}", .{formatTime(record.created_at)}) catch "";
        var image: ?[]u8 = null;
        var detail: ?[]u8 = null;
        var label: []u8 = undefined;
        switch (record.content) {
            .text => |text| {
                const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
                label = state.allocator.dupe(u8, text[0..@min(end, 200)]) catch &.{};
                detail = state.allocator.dupe(u8, text) catch null;
            },
            .image => |path| {
                label = state.allocator.dupe(u8, path) catch &.{};
                image = takePicture(state, path) orelse
                    core.previewPng(state.io, state.allocator, path, preview_side) catch null;
            },
        }
        rows[index] = .{
            .time = state.allocator.dupe(u8, stamp) catch &.{},
            .label = label,
            .detail = detail,
            .image = image,
        };
    }

    state.freeHistory();
    state.records = records;
    state.rows = rows;
    // The poll compares this: reading the history again for a write it can
    // already see would read every picture twice.
    state.history_revision = core.history.revision(state.io, state.allocator, state.environ) catch null;
    if (records.len == 0) {
        state.setMainStatus("No history yet");
        return;
    }
    if (selected_id) |id| {
        for (records, 0..) |record, index| {
            if (record.id == id) {
                state.selected = index;
                break;
            }
        }
    }
}

/// The picture a previous row holds for `path`, handed over to the new one.
fn takePicture(state: *State, path: []const u8) ?[]u8 {
    for (state.rows) |*row| {
        const bytes = row.image orelse continue;
        if (!std.mem.eql(u8, row.label, path)) continue;
        row.image = null;
        return bytes;
    }
    return null;
}

pub fn pollHistory(state: *State) bool {
    const revision = core.history.revision(state.io, state.allocator, state.environ) catch return false;
    if (state.history_revision) |current| {
        if (current == revision) return false;
    }
    state.history_revision = revision;
    loadHistory(state);
    return true;
}

pub fn copyRecord(state: *State, index: usize) void {
    if (index >= state.records.len) return;
    switch (state.records[index].content) {
        .text => |text| {
            core.clipboard.copyText(state.allocator, state.io, state.environ, text) catch {};
            state.setMainStatus("Copied to clipboard");
        },
        .image => |path| {
            core.clipboard.copyImage(state.allocator, state.io, state.environ, path) catch {};
            state.setMainStatus("Image copied to clipboard");
        },
    }
}

pub fn deleteRecord(state: *State, index: usize) void {
    if (index >= state.records.len) return;
    const id = state.records[index].id;
    core.history.delete(state.io, state.allocator, state.environ, id) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setMainStatus(std.fmt.bufPrint(&buffer, "Delete failed: {s}", .{@errorName(err)}) catch "Delete failed");
        return;
    };
    loadHistory(state);
    state.setMainStatus("History entry deleted");
}

pub fn clearHistory(state: *State) void {
    core.history.clear(state.io, state.allocator, state.environ) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setMainStatus(std.fmt.bufPrint(&buffer, "Clear failed: {s}", .{@errorName(err)}) catch "Clear failed");
        return;
    };
    loadHistory(state);
    state.setMainStatus("History cleared");
}

pub fn formatTime(timestamp: i64) []const u8 {
    const secs: u64 = if (timestamp > 0) @intCast(timestamp) else 0;
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay().calculateYearDay();
    const date = day.calculateMonthDay();
    const parts = epoch.getDaySeconds();
    return std.fmt.bufPrint(&stamp_buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{
        day.year,
        date.month.numeric(),
        date.day_index + 1,
        parts.getHoursIntoDay(),
        parts.getMinutesIntoHour(),
    }) catch "---- -- --:--";
}
