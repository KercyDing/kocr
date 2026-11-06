//! Login autostart through HKCU\Software\Microsoft\Windows\CurrentVersion\Run.

const std = @import("std");

const win32 = @import("win32");

const advapi32 = win32.advapi32;
const foundation = win32.foundation;
const registry = win32.system.registry;

const key_name = win32.zig.L("Software\\Microsoft\\Windows\\CurrentVersion\\Run");
const value_name = win32.zig.L("kocr");

pub fn enabled(
    _: std.Io,
    _: std.mem.Allocator,
    _: *const std.process.Environ.Map,
) !bool {
    var buffer: [512]u16 = undefined;
    var size: u32 = @intCast(buffer.len * @sizeOf(u16));
    const result = advapi32.RegGetValueW(
        registry.HKEY_CURRENT_USER,
        key_name,
        value_name,
        registry.RRF_RT_REG_SZ,
        null,
        &buffer,
        &size,
    );
    return result == foundation.ERROR_SUCCESS;
}

pub fn set(
    io: std.Io,
    allocator: std.mem.Allocator,
    _: *const std.process.Environ.Map,
    install: bool,
    daemon_executable: []const u8,
) !void {
    if (!install) {
        const result = advapi32.RegDeleteKeyValueW(registry.HKEY_CURRENT_USER, key_name, value_name);
        if (result != foundation.ERROR_SUCCESS and result != foundation.WIN32_ERROR.ERROR_FILE_NOT_FOUND)
            return error.RegistryWriteFailed;
        return;
    }
    if (daemon_executable.len == 0) return error.InvalidExecutable;
    const command = try std.fmt.allocPrint(allocator, "\"{s}\" --daemon", .{daemon_executable});
    defer allocator.free(command);
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, command);
    defer allocator.free(utf16);
    _ = io;
    const result = advapi32.RegSetKeyValueW(
        registry.HKEY_CURRENT_USER,
        key_name,
        value_name,
        @backingInt(registry.REG_SZ),
        utf16.ptr,
        @intCast((utf16.len + 1) * @sizeOf(u16)),
    );
    if (result != foundation.ERROR_SUCCESS) return error.RegistryWriteFailed;
}
