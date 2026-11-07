//! Child processes with the process's environment always passed along.
//!
//! A spawn without an `environ_map` rebuilds the child's environment from the
//! startup `envp`, whose cached slice a library's `unsetenv` may have
//! shortened: https://codeberg.org/ziglang/zig/issues/35512 (fixed by
//! https://codeberg.org/ziglang/zig/pulls/36817). Everything goes through
//! here so that cannot be forgotten.

const std = @import("std");

pub fn spawn(
    io: std.Io,
    environ: *const std.process.Environ.Map,
    options: std.process.SpawnOptions,
) std.process.SpawnError!std.process.Child {
    var opts = options;
    opts.environ_map = environ;
    return std.process.spawn(io, opts);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    options: std.process.RunOptions,
) std.process.RunError!std.process.RunResult {
    var opts = options;
    opts.environ_map = environ;
    return std.process.run(allocator, io, opts);
}
