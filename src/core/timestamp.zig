//! Readable timestamps for screenshot file names.

const std = @import("std");

/// Writes `prefix-YYYYMMDD-HHMMSS.ext` for the current UTC time.
pub fn fileName(
    io: std.Io,
    buffer: []u8,
    prefix: []const u8,
    extension: []const u8,
) []const u8 {
    const now = std.Io.Clock.real.now(io);
    return format(buffer, prefix, @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_s)), extension) catch "kocr.png";
}

fn format(
    buffer: []u8,
    prefix: []const u8,
    secs: u64,
    extension: []const u8,
) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.bufPrint(buffer, "{s}-{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.{s}", .{
        prefix,
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
        extension,
    });
}

test "formats screenshot names" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "kocr-19700101-000000.png",
        try format(&buffer, "kocr", 0, "png"),
    );
}
