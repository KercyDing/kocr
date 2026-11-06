const std = @import("std");

pub const Capture = enum { saved, cancelled };

pub const CaptureError = error{UnsupportedPlatform};

pub const dependencies = [_][]const u8{};

pub fn captureRegion(
    _: std.mem.Allocator,
    _: std.Io,
    _: []const u8,
) !Capture {
    return error.UnsupportedPlatform;
}
