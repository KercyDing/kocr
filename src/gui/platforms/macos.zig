//! macos platform frontend.
//! The native frontend is not implemented yet.

const std = @import("std");

const objc = @import("objc");

pub fn run(_: std.process.Init) !void {
    _ = objc;
    @compileError("macos GUI is not implemented yet");
}

pub fn runDaemon(_: std.process.Init) !void {
    @compileError("macos daemon is not implemented yet");
}
