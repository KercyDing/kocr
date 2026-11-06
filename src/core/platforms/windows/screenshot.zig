//! Full-screen region capture with a rubber-band selection overlay.

const std = @import("std");

const win32 = @import("win32");
const zignal = @import("zignal");

const user32 = win32.user32;
const gdi32 = win32.gdi32;
const kernel32 = win32.kernel32;
const wm = win32.ui.windows_and_messaging;
const gdi = win32.graphics.gdi;
const foundation = win32.foundation;
const class_name = win32.zig.L("kocr-capture-overlay");
const hint_text = win32.zig.L("Drag to select. Esc or right-click to cancel.");

var state: Overlay = undefined;
var active = false;

pub const Capture = enum { saved, cancelled };

pub const CaptureError = error{
    CaptureFailed,
    InvalidOutputPath,
};

pub const dependencies = [_][]const u8{};

const Dib = struct {
    dc: gdi.HDC,
    bitmap: gdi.HBITMAP,
    old: ?gdi.HGDIOBJ,
    bits: [*]u32,
    width: i32,
    height: i32,

    fn create(screen_dc: gdi.HDC, width: i32, height: i32) !Dib {
        const dc = gdi32.CreateCompatibleDC(screen_dc);
        errdefer _ = gdi32.DeleteDC(dc);

        var info: gdi.BITMAPINFO = std.mem.zeroes(gdi.BITMAPINFO);
        info.bmiHeader.biSize = @sizeOf(gdi.BITMAPINFOHEADER);
        info.bmiHeader.biWidth = width;
        info.bmiHeader.biHeight = -height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = gdi.BI_RGB;

        var raw: ?*anyopaque = null;
        const bitmap = gdi32.CreateDIBSection(dc, &info, gdi.DIB_RGB_COLORS, &raw, null, 0) orelse
            return CaptureError.CaptureFailed;
        errdefer _ = gdi32.DeleteObject(bitmap);
        const bits = raw orelse return CaptureError.CaptureFailed;
        const old = gdi32.SelectObject(dc, bitmap);

        return .{
            .dc = dc,
            .bitmap = bitmap,
            .old = old,
            .bits = @ptrCast(@alignCast(bits)),
            .width = width,
            .height = height,
        };
    }

    fn deinit(self: *Dib) void {
        _ = gdi32.SelectObject(self.dc, self.old);
        _ = gdi32.DeleteObject(self.bitmap);
        _ = gdi32.DeleteDC(self.dc);
    }

    fn copyFromScreen(self: *Dib, screen_dc: gdi.HDC, x: i32, y: i32) void {
        const rop = combine(gdi.ROP_CODE, .{ gdi.SRCCOPY, gdi.CAPTUREBLT });
        _ = gdi32.BitBlt(self.dc, 0, 0, self.width, self.height, screen_dc, x, y, rop);
    }

    fn dim(self: *Dib, target: *Dib) void {
        const pixels = @as([*]u32, @ptrCast(self.bits))[0..@as(usize, @intCast(self.width * self.height))];
        const output = @as([*]u32, @ptrCast(target.bits))[0..pixels.len];
        for (pixels, output) |pixel, *out| {
            out.* = (pixel >> 1) & 0x7F7F7F7F;
        }
    }
};

const Overlay = struct {
    screen: Dib,
    dimmed: Dib,
    dragging: bool = false,
    start: foundation.POINT = .{ .x = 0, .y = 0 },
    current: foundation.POINT = .{ .x = 0, .y = 0 },
    selection: foundation.RECT = std.mem.zeroes(foundation.RECT),
    has_selection: bool = false,
    cancelled: bool = false,
};

fn combine(comptime T: type, values: anytype) T {
    var bits: u32 = 0;
    inline for (values) |value| bits |= @as(u32, @bitCast(value));
    return @bitCast(bits);
}

fn normalize(rect: foundation.RECT) foundation.RECT {
    return .{
        .left = @min(rect.left, rect.right),
        .top = @min(rect.top, rect.bottom),
        .right = @max(rect.left, rect.right),
        .bottom = @max(rect.top, rect.bottom),
    };
}

fn fill(hdc: gdi.HDC, rect: foundation.RECT, color: u32) void {
    const brush = gdi32.CreateSolidBrush(@bitCast(color)) orelse return;
    defer _ = gdi32.DeleteObject(brush);
    _ = user32.FillRect(hdc, &rect, brush);
}

fn drawBorder(hdc: gdi.HDC, rect: foundation.RECT) void {
    fill(hdc, .{ .left = rect.left - 1, .top = rect.top - 1, .right = rect.right + 1, .bottom = rect.top }, 0x00FFFFFF);
    fill(hdc, .{ .left = rect.left - 1, .top = rect.top - 1, .right = rect.left, .bottom = rect.bottom + 1 }, 0x00FFFFFF);
    fill(hdc, .{ .left = rect.left - 1, .top = rect.bottom, .right = rect.right + 1, .bottom = rect.bottom + 1 }, 0x00FFFFFF);
    fill(hdc, .{ .left = rect.right, .top = rect.top - 1, .right = rect.right + 1, .bottom = rect.bottom + 1 }, 0x00FFFFFF);
    fill(hdc, .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, 0x00000000);
    fill(hdc, .{ .left = rect.left, .top = rect.top, .right = rect.left + 1, .bottom = rect.bottom }, 0x00000000);
    fill(hdc, .{ .left = rect.left, .top = rect.bottom - 1, .right = rect.right, .bottom = rect.bottom }, 0x00000000);
    fill(hdc, .{ .left = rect.right - 1, .top = rect.top, .right = rect.right, .bottom = rect.bottom }, 0x00000000);
}

fn drawHint(hdc: gdi.HDC) void {
    const box = foundation.RECT{ .left = 12, .top = 12, .right = 520, .bottom = 48 };
    fill(hdc, box, 0x00202020);
    const font = gdi32.GetStockObject(gdi.DEFAULT_GUI_FONT);
    const old_font = gdi32.SelectObject(hdc, font);
    defer _ = gdi32.SelectObject(hdc, old_font);
    _ = gdi32.SetTextColor(hdc, @bitCast(@as(u32, 0x00FFFFFF)));
    _ = gdi32.SetBkMode(hdc, gdi.TRANSPARENT);
    _ = gdi32.TextOutW(hdc, 22, 20, hint_text.ptr, hint_text.len);
}

fn paint(hwnd: foundation.HWND) void {
    var paint_struct: gdi.PAINTSTRUCT = undefined;
    const hdc = user32.BeginPaint(hwnd, &paint_struct) orelse return;
    defer _ = user32.EndPaint(hwnd, &paint_struct);

    _ = gdi32.BitBlt(hdc, 0, 0, state.dimmed.width, state.dimmed.height, state.dimmed.dc, 0, 0, gdi.SRCCOPY);
    if (state.has_selection and state.selection.right > state.selection.left and state.selection.bottom > state.selection.top) {
        _ = gdi32.BitBlt(
            hdc,
            state.selection.left,
            state.selection.top,
            state.selection.right - state.selection.left,
            state.selection.bottom - state.selection.top,
            state.screen.dc,
            state.selection.left,
            state.selection.top,
            gdi.SRCCOPY,
        );
        drawBorder(hdc, state.selection);
    }
    drawHint(hdc);
}

fn overlayProc(hwnd: foundation.HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    switch (message) {
        wm.WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        wm.WM_ERASEBKGND => return 1,
        wm.WM_LBUTTONDOWN => {
            state.dragging = true;
            state.start = win32.zig.pointFromLparam(lparam);
            state.current = state.start;
            _ = user32.SetCapture(hwnd);
            return 0;
        },
        wm.WM_MOUSEMOVE => {
            if (!state.dragging) return 0;
            state.current = win32.zig.pointFromLparam(lparam);
            state.selection = normalize(.{
                .left = state.start.x,
                .top = state.start.y,
                .right = state.current.x,
                .bottom = state.current.y,
            });
            state.has_selection = true;
            _ = user32.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        wm.WM_LBUTTONUP => {
            if (!state.dragging) return 0;
            state.dragging = false;
            _ = user32.ReleaseCapture();
            state.current = win32.zig.pointFromLparam(lparam);
            state.selection = normalize(.{
                .left = state.start.x,
                .top = state.start.y,
                .right = state.current.x,
                .bottom = state.current.y,
            });
            state.has_selection = true;
            if (state.selection.right - state.selection.left < 2 or state.selection.bottom - state.selection.top < 2) {
                state.has_selection = false;
                return 0;
            }
            _ = user32.DestroyWindow(hwnd);
            return 0;
        },
        wm.WM_RBUTTONUP => {
            state.cancelled = true;
            _ = user32.DestroyWindow(hwnd);
            return 0;
        },
        wm.WM_KEYDOWN => {
            if (wparam == @backingInt(win32.ui.input.keyboard_and_mouse.VIRTUAL_KEY.ESCAPE)) {
                state.cancelled = true;
                _ = user32.DestroyWindow(hwnd);
            }
            return 0;
        },
        wm.WM_SETCURSOR => {
            _ = user32.SetCursor(user32.LoadCursorW(null, wm.IDC_CROSS));
            return 1;
        },
        wm.WM_DESTROY => {
            user32.PostQuitMessage(0);
            return 0;
        },
        else => return user32.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

pub fn captureRegion(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_path: []const u8,
) !Capture {
    if (output_path.len == 0) return CaptureError.InvalidOutputPath;
    if (active) return CaptureError.CaptureFailed;
    active = true;
    defer active = false;

    const x = user32.GetSystemMetrics(wm.SM_XVIRTUALSCREEN);
    const y = user32.GetSystemMetrics(wm.SM_YVIRTUALSCREEN);
    const width = user32.GetSystemMetrics(wm.SM_CXVIRTUALSCREEN);
    const height = user32.GetSystemMetrics(wm.SM_CYVIRTUALSCREEN);
    if (width <= 0 or height <= 0) return CaptureError.CaptureFailed;

    const screen_dc = user32.GetDC(null) orelse return CaptureError.CaptureFailed;
    defer _ = user32.ReleaseDC(null, screen_dc);

    var screen = try Dib.create(screen_dc, width, height);
    defer screen.deinit();
    screen.copyFromScreen(screen_dc, x, y);

    var dimmed = try Dib.create(screen_dc, width, height);
    defer dimmed.deinit();
    screen.dim(&dimmed);

    state = .{ .screen = screen, .dimmed = dimmed };

    const instance = kernel32.GetModuleHandleW(null);
    var window_class: wm.WNDCLASSEXW = std.mem.zeroes(wm.WNDCLASSEXW);
    window_class.cbSize = @sizeOf(wm.WNDCLASSEXW);
    window_class.style = combine(wm.WNDCLASS_STYLES, .{ wm.CS_HREDRAW, wm.CS_VREDRAW });
    window_class.lpfnWndProc = &overlayProc;
    window_class.hInstance = instance;
    window_class.hCursor = user32.LoadCursorW(null, wm.IDC_CROSS);
    window_class.lpszClassName = class_name;
    _ = user32.RegisterClassExW(&window_class);

    const style = combine(wm.WINDOW_STYLE, .{ wm.WS_POPUP, wm.WS_VISIBLE });
    const ex_style = combine(wm.WINDOW_EX_STYLE, .{ wm.WS_EX_TOPMOST, wm.WS_EX_TOOLWINDOW });
    const hwnd = user32.CreateWindowExW(
        ex_style,
        class_name,
        class_name,
        style,
        x,
        y,
        width,
        height,
        null,
        null,
        instance,
        null,
    ) orelse return CaptureError.CaptureFailed;
    _ = user32.ShowWindow(hwnd, wm.SW_SHOW);
    _ = user32.SetForegroundWindow(hwnd);
    _ = user32.UpdateWindow(hwnd);

    var message: wm.MSG = undefined;
    while (user32.GetMessageW(&message, null, 0, 0) > 0) {
        _ = user32.TranslateMessage(&message);
        _ = user32.DispatchMessageW(&message);
    }

    if (state.cancelled or !state.has_selection) return .cancelled;

    const rect = state.selection;
    const selection_width: usize = @intCast(rect.right - rect.left);
    const selection_height: usize = @intCast(rect.bottom - rect.top);
    const pixels = try allocator.alloc(zignal.Rgb(u8), selection_width * selection_height);
    defer allocator.free(pixels);

    for (0..selection_height) |row| {
        for (0..selection_width) |column| {
            const source_index = @as(usize, @intCast(rect.top + @as(i32, @intCast(row)))) * @as(usize, @intCast(state.screen.width)) +
                @as(usize, @intCast(rect.left + @as(i32, @intCast(column))));
            const pixel = state.screen.bits[source_index];
            pixels[row * selection_width + column] = .{
                .r = @truncate((pixel >> 16) & 0xFF),
                .g = @truncate((pixel >> 8) & 0xFF),
                .b = @truncate(pixel & 0xFF),
            };
        }
    }

    const image = zignal.Image(zignal.Rgb(u8)).initFromSlice(
        @intCast(selection_height),
        @intCast(selection_width),
        pixels,
    );
    image.save(io, allocator, output_path) catch return CaptureError.CaptureFailed;
    return .saved;
}
