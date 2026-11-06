//! Windows clipboard text and image support.

const std = @import("std");

const win32 = @import("win32");
const zignal = @import("zignal");

const user32 = win32.user32;
const kernel32 = win32.kernel32;
const gdi = win32.graphics.gdi;
const ole = win32.system.ole;
const memory = win32.system.memory;

pub const ClipboardError = error{
    ClipboardUnavailable,
    ClipboardWriteFailed,
};

pub fn copyText(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: *const std.process.Environ.Map,
    text: []const u8,
) !void {
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(utf16);
    try writeClipboard(io, @backingInt(ole.CF_UNICODETEXT), std.mem.sliceAsBytes(utf16));
}

pub fn copyImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: *const std.process.Environ.Map,
    path: []const u8,
) !void {
    var image = zignal.Image(zignal.Rgb(u8)).load(io, allocator, path) catch return ClipboardError.ClipboardWriteFailed;
    defer image.deinit(allocator);

    const header_size = @sizeOf(gdi.BITMAPINFOHEADER);
    const pixel_bytes = @as(usize, image.cols) * @as(usize, image.rows) * 4;
    const total = header_size + pixel_bytes;

    const handle = kernel32.GlobalAlloc(memory.GMEM_MOVEABLE, total);
    if (handle == 0) return ClipboardError.ClipboardUnavailable;
    const raw = kernel32.GlobalLock(handle) orelse {
        _ = kernel32.GlobalFree(handle);
        return ClipboardError.ClipboardUnavailable;
    };
    defer _ = kernel32.GlobalUnlock(handle);

    const bytes: [*]u8 = @ptrCast(raw);
    const header: *gdi.BITMAPINFOHEADER = @ptrCast(@alignCast(bytes));
    header.* = std.mem.zeroes(gdi.BITMAPINFOHEADER);
    header.biSize = header_size;
    header.biWidth = @intCast(image.cols);
    header.biHeight = @intCast(image.rows);
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = gdi.BI_RGB;
    header.biSizeImage = @intCast(pixel_bytes);

    const pixels: [*]u32 = @ptrCast(@alignCast(bytes + header_size));
    for (0..image.rows) |row| {
        for (0..image.cols) |column| {
            const pixel = image.data[row * image.stride + column];
            const value = (@as(u32, pixel.r) << 16) | (@as(u32, pixel.g) << 8) | pixel.b;
            pixels[(image.rows - 1 - row) * image.cols + column] = value;
        }
    }

    try writeHandle(io, @backingInt(ole.CF_DIB), handle);
}

fn writeClipboard(io: std.Io, format: u32, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const handle = kernel32.GlobalAlloc(memory.GMEM_MOVEABLE, bytes.len);
    if (handle == 0) return ClipboardError.ClipboardUnavailable;
    const raw = kernel32.GlobalLock(handle) orelse {
        _ = kernel32.GlobalFree(handle);
        return ClipboardError.ClipboardUnavailable;
    };
    const destination: [*]u8 = @ptrCast(raw);
    @memcpy(destination[0..bytes.len], bytes);
    _ = kernel32.GlobalUnlock(handle);
    try writeHandle(io, format, handle);
}

fn writeHandle(io: std.Io, format: u32, handle: isize) !void {
    var attempts: usize = 0;
    while (user32.OpenClipboard(null) == 0) {
        attempts += 1;
        if (attempts >= 20) {
            _ = kernel32.GlobalFree(handle);
            return ClipboardError.ClipboardUnavailable;
        }
        std.Io.sleep(io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .awake) catch {};
    }
    defer _ = user32.CloseClipboard();
    if (user32.EmptyClipboard() == 0) {
        _ = kernel32.GlobalFree(handle);
        return ClipboardError.ClipboardUnavailable;
    }
    const pointer: ?*anyopaque = @ptrFromInt(@as(usize, @intCast(handle)));
    if (user32.SetClipboardData(format, pointer) == null) {
        _ = kernel32.GlobalFree(handle);
        return ClipboardError.ClipboardWriteFailed;
    }
}
