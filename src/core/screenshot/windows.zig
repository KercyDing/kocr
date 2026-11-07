//! Per-monitor frozen-screen region capture with a layered selection overlay.
//!
//! The screen is captured once, then shown in a `WS_EX_LAYERED` window: the
//! whole frame is blended toward a dark tint, and the drag region toward a
//! light one. The overlay never repaints the desktop, so dragging cannot
//! flicker.

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
const hint_face = win32.zig.L("Segoe UI");

// Blend weights out of 255: the frozen screen is tinted dark, the selection
// light, so the drag reads as a translucent mask over a frozen screen.
const blend_alpha: u16 = 64;
const mask_tint: u8 = 0x20;
const selection_tint: u8 = 0xd0;

var active = false;

pub const Capture = enum { saved, cancelled };

pub const CaptureError = error{
    CaptureFailed,
    InvalidOutputPath,
};

pub const dependencies = [_][]const u8{};

const Surface = struct {
    dc: gdi.HDC,
    bitmap: gdi.HBITMAP,
    old: ?gdi.HGDIOBJ,
    bits: [*]u32,
    width: i32,
    height: i32,

    fn create(screen_dc: gdi.HDC, width: i32, height: i32) !Surface {
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

    fn deinit(self: *Surface) void {
        _ = gdi32.SelectObject(self.dc, self.old);
        _ = gdi32.DeleteObject(self.bitmap);
        _ = gdi32.DeleteDC(self.dc);
    }

    fn pixels(self: *Surface) []u32 {
        return self.bits[0..@intCast(self.width * self.height)];
    }

    fn copyFromScreen(self: *Surface, screen_dc: gdi.HDC, x: i32, y: i32) void {
        const rop = combine(gdi.ROP_CODE, .{ gdi.SRCCOPY, gdi.CAPTUREBLT });
        _ = gdi32.BitBlt(self.dc, 0, 0, self.width, self.height, screen_dc, x, y, rop);
    }
};

const Overlay = struct {
    surface: Surface,
    screen: Surface,
    background: []u32,
    start: ?foundation.POINT = null,
    current: foundation.POINT = .{ .x = 0, .y = 0 },
    selection: ?foundation.RECT = null,
    cancelled: bool = false,
    font: ?gdi.HFONT = null,
    font_dpi: u32 = 0,
};

fn combine(comptime T: type, values: anytype) T {
    var bits: u32 = 0;
    inline for (values) |value| bits |= @as(u32, @bitCast(value));
    return @bitCast(bits);
}

fn mix(channel: u8, tint: u8, alpha: u16) u8 {
    return @intCast((@as(u16, channel) * (255 - alpha) + @as(u16, tint) * alpha) / 255);
}

/// Blends one BGRA pixel toward `tint`, keeping it opaque.
fn tinted(pixel: u32, tint: u8, alpha: u16) u32 {
    const blue = mix(@truncate(pixel & 0xFF), tint, alpha);
    const green = mix(@truncate((pixel >> 8) & 0xFF), tint, alpha);
    const red = mix(@truncate((pixel >> 16) & 0xFF), tint, alpha);
    return 0xFF000000 | (@as(u32, red) << 16) | (@as(u32, green) << 8) | blue;
}

fn clampPoint(overlay: *const Overlay, point: foundation.POINT) foundation.POINT {
    return .{
        .x = std.math.clamp(point.x, 0, overlay.surface.width - 1),
        .y = std.math.clamp(point.y, 0, overlay.surface.height - 1),
    };
}

fn dragRect(overlay: *const Overlay) ?foundation.RECT {
    const start = overlay.start orelse return null;
    return .{
        .left = @min(start.x, overlay.current.x),
        .top = @min(start.y, overlay.current.y),
        .right = @max(start.x, overlay.current.x),
        .bottom = @max(start.y, overlay.current.y),
    };
}

fn drawSelection(overlay: *Overlay, rect: foundation.RECT) void {
    const width = overlay.surface.width;
    const pixels = overlay.surface.pixels();
    const left = @max(rect.left, 0);
    const top = @max(rect.top, 0);
    const right = @min(rect.right, width);
    const bottom = @min(rect.bottom, overlay.surface.height);
    var y = top;
    while (y < bottom) : (y += 1) {
        var x = left;
        while (x < right) : (x += 1) {
            const index = @as(usize, @intCast(y)) * @as(usize, @intCast(width)) + @as(usize, @intCast(x));
            const border = x == left or y == top or x + 1 == right or y + 1 == bottom;
            pixels[index] = if (border) 0xFFFFFFFF else tinted(pixels[index], selection_tint, blend_alpha);
        }
    }
}

fn forceOpaque(surface: *Surface, rect: foundation.RECT) void {
    const width = surface.width;
    const pixels = surface.pixels();
    const left = @max(rect.left, 0);
    const top = @max(rect.top, 0);
    const right = @min(rect.right, width);
    const bottom = @min(rect.bottom, surface.height);
    var y = top;
    while (y < bottom) : (y += 1) {
        var x = left;
        while (x < right) : (x += 1) {
            const index = @as(usize, @intCast(y)) * @as(usize, @intCast(width)) + @as(usize, @intCast(x));
            pixels[index] |= 0xFF000000;
        }
    }
}

fn createHintFont(dpi: u32) ?gdi.HFONT {
    // 12pt Segoe UI with grayscale antialiasing: ClearType's subpixel filter
    // assumes an opaque background and produces colored fringes on a layered
    // surface, which reads as blur.
    const height: i32 = -@divTrunc(12 * @as(i32, @intCast(dpi)), 72);
    return gdi32.CreateFontW(
        height,
        0,
        0,
        0,
        @backingInt(gdi.FW_NORMAL),
        0,
        0,
        0,
        @backingInt(gdi.DEFAULT_CHARSET),
        @backingInt(gdi.OUT_TT_PRECIS),
        @as(u32, @as(u8, @bitCast(gdi.CLIP_DEFAULT_PRECIS))),
        @backingInt(gdi.ANTIALIASED_QUALITY),
        @backingInt(gdi.DEFAULT_PITCH),
        hint_face,
    );
}

fn scale(value: i32, dpi: u32) i32 {
    return @divTrunc(value * @as(i32, @intCast(dpi)), 96);
}

fn drawHint(overlay: *Overlay, dpi: u32) void {
    const surface = &overlay.surface;
    if (overlay.font == null or overlay.font_dpi != dpi) {
        if (overlay.font) |font| _ = gdi32.DeleteObject(font);
        overlay.font = createHintFont(dpi);
        overlay.font_dpi = dpi;
    }

    var old_font: ?gdi.HGDIOBJ = null;
    if (overlay.font) |font| old_font = gdi32.SelectObject(surface.dc, font);
    defer {
        if (old_font) |old| _ = gdi32.SelectObject(surface.dc, old);
    }

    // Size the plate to the text rather than a fixed strip. The fallback keeps
    // the text covered if measurement fails.
    var extent = foundation.SIZE{ .cx = scale(480, dpi), .cy = scale(20, dpi) };
    _ = gdi32.GetTextExtentPoint32W(surface.dc, hint_text.ptr, hint_text.len, &extent);

    const pad_x = scale(10, dpi);
    const pad_y = scale(6, dpi);
    const plate_width = extent.cx + pad_x * 2;
    const plate_height = extent.cy + pad_y * 2;
    const plate_left = @max(@divTrunc(surface.width - plate_width, 2), 0);
    const plate_top = scale(12, dpi);
    const box = foundation.RECT{
        .left = plate_left,
        .top = plate_top,
        .right = plate_left + plate_width,
        .bottom = plate_top + plate_height,
    };
    const brush = gdi32.CreateSolidBrush(@bitCast(@as(u32, 0x003C3C3C))) orelse return;
    defer _ = gdi32.DeleteObject(brush);
    _ = user32.FillRect(surface.dc, &box, brush);

    _ = gdi32.SetTextColor(surface.dc, @bitCast(@as(u32, 0x00FFFFFF)));
    _ = gdi32.SetBkMode(surface.dc, gdi.TRANSPARENT);
    _ = gdi32.TextOutW(
        surface.dc,
        box.left + pad_x,
        box.top + pad_y,
        hint_text.ptr,
        hint_text.len,
    );

    // GDI does not maintain the alpha channel of a 32-bit DIB section; without
    // this the hint would punch a transparent hole in the layered window.
    forceOpaque(surface, box);
}

fn updateLayered(hwnd: foundation.HWND, surface: *const Surface) void {
    var size = foundation.SIZE{ .cx = surface.width, .cy = surface.height };
    var source = foundation.POINT{ .x = 0, .y = 0 };
    var blend = gdi.BLENDFUNCTION{
        .BlendOp = @intCast(gdi.AC_SRC_OVER),
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = @intCast(gdi.AC_SRC_ALPHA),
    };
    _ = user32.UpdateLayeredWindow(hwnd, null, null, &size, surface.dc, &source, @bitCast(@as(u32, 0)), &blend, wm.ULW_ALPHA);
}

fn refresh(hwnd: foundation.HWND, overlay: *Overlay) void {
    const pixels = overlay.surface.pixels();
    @memcpy(pixels, overlay.background);
    if (dragRect(overlay)) |rect| drawSelection(overlay, rect);
    var dpi = user32.GetDpiForWindow(hwnd);
    if (dpi == 0) dpi = 96;
    drawHint(overlay, dpi);
    updateLayered(hwnd, &overlay.surface);
}

fn freeze(overlay: *Overlay) void {
    const source = overlay.screen.pixels();
    for (source, overlay.background) |pixel, *out| {
        out.* = tinted(pixel, mask_tint, blend_alpha);
    }
}

fn overlayFrom(hwnd: foundation.HWND) ?*Overlay {
    const raw = user32.GetWindowLongPtrW(hwnd, wm.GWLP_USERDATA);
    if (raw == 0) return null;
    const pointer: *anyopaque = @ptrFromInt(@as(usize, @bitCast(raw)));
    return @ptrCast(@alignCast(pointer));
}

fn dismiss(hwnd: foundation.HWND, cancelled: bool) void {
    const overlay = overlayFrom(hwnd) orelse return;
    overlay.cancelled = cancelled;
    _ = user32.ReleaseCapture();
    _ = user32.DestroyWindow(hwnd);
}

fn overlayProc(hwnd: foundation.HWND, message: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    if (message == wm.WM_NCCREATE) {
        const create: *const wm.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (create.lpCreateParams) |params| {
            _ = user32.SetWindowLongPtrW(hwnd, wm.GWLP_USERDATA, @bitCast(@as(usize, @intFromPtr(params))));
        }
        return user32.DefWindowProcW(hwnd, message, wparam, lparam);
    }

    const overlay = overlayFrom(hwnd) orelse return user32.DefWindowProcW(hwnd, message, wparam, lparam);

    switch (message) {
        // Layered windows are hit-tested per pixel; keep the whole surface
        // interactive so a drag can start anywhere.
        wm.WM_NCHITTEST => return @intCast(wm.HTCLIENT),
        wm.WM_SETCURSOR => {
            _ = user32.SetCursor(user32.LoadCursorW(null, wm.IDC_CROSS));
            return 1;
        },
        wm.WM_LBUTTONDOWN => {
            const point = clampPoint(overlay, win32.zig.pointFromLparam(lparam));
            overlay.start = point;
            overlay.current = point;
            _ = user32.SetCapture(hwnd);
            refresh(hwnd, overlay);
            return 0;
        },
        wm.WM_MOUSEMOVE => {
            _ = user32.SetCursor(user32.LoadCursorW(null, wm.IDC_CROSS));
            if (overlay.start != null) {
                const point = clampPoint(overlay, win32.zig.pointFromLparam(lparam));
                if (!std.meta.eql(point, overlay.current)) {
                    overlay.current = point;
                    refresh(hwnd, overlay);
                }
            }
            return 0;
        },
        wm.WM_LBUTTONUP => {
            if (overlay.start) |start| {
                const point = clampPoint(overlay, win32.zig.pointFromLparam(lparam));
                overlay.start = null;
                overlay.selection = .{
                    .left = @min(start.x, point.x),
                    .top = @min(start.y, point.y),
                    .right = @max(start.x, point.x),
                    .bottom = @max(start.y, point.y),
                };
                _ = user32.ReleaseCapture();
                _ = user32.DestroyWindow(hwnd);
            }
            return 0;
        },
        wm.WM_RBUTTONDOWN, wm.WM_CLOSE => {
            dismiss(hwnd, true);
            return 0;
        },
        wm.WM_KEYDOWN => {
            if (wparam == @backingInt(win32.ui.input.keyboard_and_mouse.VIRTUAL_KEY.ESCAPE)) {
                dismiss(hwnd, true);
                return 0;
            }
            return user32.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        wm.WM_ERASEBKGND => return 1,
        wm.WM_PAINT => {
            var paint_struct: gdi.PAINTSTRUCT = undefined;
            _ = user32.BeginPaint(hwnd, &paint_struct);
            _ = user32.EndPaint(hwnd, &paint_struct);
            refresh(hwnd, overlay);
            return 0;
        },
        wm.WM_DESTROY => return 0,
        else => return user32.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn createOverlay(overlay: *Overlay, bounds: foundation.RECT) !foundation.HWND {
    const instance = kernel32.GetModuleHandleW(null);

    var window_class: wm.WNDCLASSEXW = std.mem.zeroes(wm.WNDCLASSEXW);
    window_class.cbSize = @sizeOf(wm.WNDCLASSEXW);
    window_class.lpfnWndProc = &overlayProc;
    window_class.hInstance = instance;
    window_class.hCursor = user32.LoadCursorW(null, wm.IDC_CROSS);
    window_class.lpszClassName = class_name;
    // A zero return here can also mean this process registered the class during
    // an earlier capture; CreateWindowExW still uses that class.
    _ = user32.RegisterClassExW(&window_class);

    const ex_style = combine(wm.WINDOW_EX_STYLE, .{ wm.WS_EX_LAYERED, wm.WS_EX_TOPMOST, wm.WS_EX_TOOLWINDOW });
    const hwnd = user32.CreateWindowExW(
        ex_style,
        class_name,
        class_name,
        wm.WS_POPUP,
        bounds.left,
        bounds.top,
        bounds.right - bounds.left,
        bounds.bottom - bounds.top,
        null,
        null,
        instance,
        overlay,
    ) orelse return CaptureError.CaptureFailed;

    // Paint the surface before showing, so the window never flashes empty.
    refresh(hwnd, overlay);
    _ = user32.ShowWindow(hwnd, wm.SW_SHOW);
    _ = user32.SetForegroundWindow(hwnd);
    _ = user32.SetFocus(hwnd);
    return hwnd;
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

    // Monitor bounds, window placement, and the captured bitmap must all be in
    // physical pixels. The GUI already opts into per-monitor v2 before creating
    // windows; other callers may not have.
    _ = user32.SetProcessDpiAwarenessContext(win32.ui.hi_dpi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    var cursor: foundation.POINT = undefined;
    if (user32.GetCursorPos(&cursor) == 0) return CaptureError.CaptureFailed;
    const monitor = user32.MonitorFromPoint(cursor, gdi.MONITOR_DEFAULTTONEAREST) orelse
        return CaptureError.CaptureFailed;
    var monitor_info: gdi.MONITORINFO = std.mem.zeroes(gdi.MONITORINFO);
    monitor_info.cbSize = @sizeOf(gdi.MONITORINFO);
    if (user32.GetMonitorInfoW(monitor, &monitor_info) == 0) return CaptureError.CaptureFailed;

    const bounds = monitor_info.rcMonitor;
    const width = bounds.right - bounds.left;
    const height = bounds.bottom - bounds.top;
    if (width <= 0 or height <= 0) return CaptureError.CaptureFailed;

    const screen_dc = user32.GetDC(null) orelse return CaptureError.CaptureFailed;
    defer _ = user32.ReleaseDC(null, screen_dc);

    var overlay: Overlay = .{
        .surface = try Surface.create(screen_dc, width, height),
        .screen = undefined,
        .background = undefined,
    };
    defer overlay.surface.deinit();
    overlay.screen = try Surface.create(screen_dc, width, height);
    defer overlay.screen.deinit();
    overlay.background = try allocator.alloc(u32, @as(usize, @intCast(width)) * @as(usize, @intCast(height)));
    defer allocator.free(overlay.background);
    defer {
        if (overlay.font) |font| _ = gdi32.DeleteObject(font);
    }

    overlay.screen.copyFromScreen(screen_dc, bounds.left, bounds.top);
    freeze(&overlay);
    @memcpy(overlay.surface.pixels(), overlay.background);

    const hwnd = try createOverlay(&overlay, bounds);
    defer _ = user32.DestroyWindow(hwnd);

    _ = user32.SetCursor(user32.LoadCursorW(null, wm.IDC_CROSS));
    _ = user32.SetCapture(hwnd);

    var message: wm.MSG = undefined;
    while (true) {
        if (user32.GetMessageW(&message, null, 0, 0) <= 0) break;
        _ = user32.TranslateMessage(&message);
        _ = user32.DispatchMessageW(&message);
        if (overlay.selection != null or overlay.cancelled) break;
    }
    _ = user32.ReleaseCapture();

    if (overlay.cancelled) return .cancelled;
    const rect = overlay.selection orelse return .cancelled;
    const selection_width: usize = @intCast(rect.right - rect.left);
    const selection_height: usize = @intCast(rect.bottom - rect.top);
    if (selection_width == 0 or selection_height == 0) return .cancelled;

    const pixels = try allocator.alloc(zignal.Rgb(u8), selection_width * selection_height);
    defer allocator.free(pixels);

    const screen_pixels = overlay.screen.pixels();
    const image_width: usize = @intCast(overlay.screen.width);
    for (0..selection_height) |row| {
        for (0..selection_width) |column| {
            const source_index = (@as(usize, @intCast(rect.top)) + row) * image_width +
                @as(usize, @intCast(rect.left)) + column;
            const pixel = screen_pixels[source_index];
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
