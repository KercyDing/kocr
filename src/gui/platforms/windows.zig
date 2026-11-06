//! windows platform frontend.
//! The native frontend is not implemented yet.

const std = @import("std");

const win32 = @import("win32");

pub fn run(_: std.process.Init) !void {
    _ = win32;
    @compileError("windows GUI is not implemented yet");
}

pub fn runDaemon(_: std.process.Init) !void {
    @compileError("windows daemon is not implemented yet");
}
