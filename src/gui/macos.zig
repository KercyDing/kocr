//! macOS GUI entry point.
//! zig-objc is wired through the build; the native frontend is not implemented yet.

const std = @import("std");

const objc = @import("objc");

pub fn run(_: std.process.Init) !void {
    _ = objc;
    @compileError("macOS GUI is not implemented yet");
}

pub fn main(init: std.process.Init) !void {
    try run(init);
}
