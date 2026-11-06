//! macOS daemon: the same nanoui-based loop as Windows; the macOS platform
//! layer still stubs capture, shortcuts, and clipboard.

pub const run = @import("windows.zig").run;
