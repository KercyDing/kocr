//! Model profiles and selection.

const std = @import("std");

const core = @import("core");

const state_mod = @import("state.zig");

const config = core.config;
const State = state_mod.State;

pub const profiles = [_][]const u8{ "tiny", "small", "medium" };

pub fn selectedProfile(state: *State) []const u8 {
    return profiles[@min(state.profile_index, profiles.len - 1)];
}

pub fn updateModelStatus(state: *State) bool {
    if (state.job != null) return false;
    const profile = selectedProfile(state);
    const installed = core.downloader.isInstalled(state.io, state.allocator, state.environ, profile) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setSettingsStatus(std.fmt.bufPrint(&buffer, "Model status error: {s}", .{@errorName(err)}) catch "Model status error");
        return false;
    };
    if (installed == state.installed) return false;
    state.installed = installed;
    return true;
}

pub fn loadSelection(state: *State) void {
    var parsed = config.load(state.allocator, state.io, state.environ) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setMainStatus(std.fmt.bufPrint(&buffer, "Config error: {s}", .{@errorName(err)}) catch "Config error");
        return;
    };
    defer parsed.deinit();
    const selected = parsed.value.models.select orelse return;
    for (profiles, 0..) |profile, index| {
        if (std.mem.eql(u8, selected, profile)) {
            state.profile_index = index;
            return;
        }
    }
}

pub fn saveSelection(state: *State) void {
    var parsed = config.load(state.allocator, state.io, state.environ) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setSettingsStatus(std.fmt.bufPrint(&buffer, "Config error: {s}", .{@errorName(err)}) catch "Config error");
        return;
    };
    defer parsed.deinit();
    parsed.value.models.select = selectedProfile(state);
    config.save(state.allocator, state.io, state.environ, parsed.value) catch |err| {
        var buffer: [256]u8 = undefined;
        state.setSettingsStatus(std.fmt.bufPrint(&buffer, "Could not save config: {s}", .{@errorName(err)}) catch "Could not save config");
    };
}
