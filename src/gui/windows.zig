//! Windows GUI entry point.
//! zigwin32 is wired through the build; the native frontend is not implemented yet.

const std = @import("std");

const win32 = @import("win32");

pub fn run(_: std.process.Init) !void {
    _ = win32;
    @compileError("Windows GUI is not implemented yet");
}

pub fn main(init: std.process.Init) !void {
    try run(init);
}
