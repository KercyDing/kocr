use std::fs;
use std::path::Path;

use image::RgbaImage;
use image::imageops::crop_imm;
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, POINT, RECT, SIZE, WPARAM};
use windows::Win32::Graphics::Gdi::{
    AC_SRC_ALPHA, AC_SRC_OVER, BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BLENDFUNCTION, BeginPaint,
    CreateCompatibleDC, CreateDIBSection, DIB_RGB_COLORS, DeleteDC, DeleteObject, EndPaint,
    HBITMAP, HDC, HGDIOBJ, PAINTSTRUCT, SelectObject,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture, SetFocus};
use windows::Win32::UI::WindowsAndMessaging::{
    CREATESTRUCTW, CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GWLP_USERDATA,
    GetCursorPos, GetMessageW, GetWindowLongPtrW, IDC_CROSS, LoadCursorW, MSG, RegisterClassW,
    SW_SHOW, SetCursor, SetForegroundWindow, SetWindowLongPtrW, ShowWindow, TranslateMessage,
    ULW_ALPHA, UpdateLayeredWindow, WM_DESTROY, WM_ERASEBKGND, WM_KEYDOWN, WM_LBUTTONDOWN,
    WM_LBUTTONUP, WM_MOUSEMOVE, WM_NCCREATE, WM_NCHITTEST, WM_PAINT, WM_RBUTTONDOWN, WM_SETCURSOR,
    WNDCLASSW, WS_EX_LAYERED, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
};
use windows::Win32::UI::WindowsAndMessaging::{WINDOW_EX_STYLE, WINDOW_STYLE};
use windows::core::w;
use xcap::Monitor;

use super::{Capture, PlatformError};

const OVERLAY_ALPHA: u8 = 64;
const GWLP_USERDATA_INDEX: windows::Win32::UI::WindowsAndMessaging::WINDOW_LONG_PTR_INDEX =
    GWLP_USERDATA;
struct OverlayRender {
    hdc: HDC,
    bitmap: HBITMAP,
    old_bitmap: HGDIOBJ,
    bits: *mut u8,
    background: Vec<u8>,
    frame: Vec<u8>,
    width: usize,
    height: usize,
}

impl Drop for OverlayRender {
    fn drop(&mut self) {
        unsafe {
            let _ = SelectObject(self.hdc, self.old_bitmap);
            let _ = DeleteObject(HGDIOBJ(self.bitmap.0));
            let _ = DeleteDC(self.hdc);
        }
    }
}

impl OverlayRender {
    fn new(width: usize, height: usize, background: Vec<u8>) -> Result<Self, PlatformError> {
        let frame = background.clone();
        let hdc = unsafe { CreateCompatibleDC(None) };
        if hdc.0.is_null() {
            return Err(PlatformError::Output(
                "could not create overlay memory DC".to_owned(),
            ));
        }
        let info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: width as i32,
                biHeight: -(height as i32),
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let mut bits = std::ptr::null_mut();
        let bitmap =
            unsafe { CreateDIBSection(Some(hdc), &info, DIB_RGB_COLORS, &mut bits, None, 0) }
                .map_err(|error| {
                    unsafe {
                        let _ = DeleteDC(hdc);
                    }
                    PlatformError::Output(format!("could not create overlay bitmap: {error}"))
                })?;
        if bits.is_null() {
            unsafe {
                let _ = DeleteObject(HGDIOBJ(bitmap.0));
                let _ = DeleteDC(hdc);
            }
            return Err(PlatformError::Output(
                "overlay bitmap returned no pixel buffer".to_owned(),
            ));
        }
        let old_bitmap = unsafe { SelectObject(hdc, HGDIOBJ(bitmap.0)) };
        Ok(Self {
            hdc,
            bitmap,
            old_bitmap,
            bits: bits.cast(),
            background,
            frame,
            width,
            height,
        })
    }

    fn set_background(&mut self, background: Vec<u8>) {
        debug_assert_eq!(background.len(), self.background.len());
        self.background = background;
        self.frame.copy_from_slice(&self.background);
    }

    fn draw(&mut self, selection: Option<RECT>) {
        self.frame.copy_from_slice(&self.background);
        if let Some(selection) = selection {
            let left = selection.left.max(0) as usize;
            let top = selection.top.max(0) as usize;
            let right = (selection.right.max(0) as usize).min(self.width);
            let bottom = (selection.bottom.max(0) as usize).min(self.height);
            for y in top..bottom {
                for x in left..right {
                    let index = (y * self.width + x) * 4;
                    let border = x == left || y == top || x + 1 == right || y + 1 == bottom;
                    if border {
                        self.frame[index..index + 4].copy_from_slice(&[255, 255, 255, 255]);
                    } else {
                        for channel in &mut self.frame[index..index + 3] {
                            *channel = ((*channel as u16 * (255 - OVERLAY_ALPHA as u16)
                                + 0xd0 * OVERLAY_ALPHA as u16)
                                / 255) as u8;
                        }
                    }
                }
            }
        }
        unsafe {
            std::ptr::copy_nonoverlapping(self.frame.as_ptr(), self.bits, self.frame.len());
        }
    }
}

fn frozen_background(image: &RgbaImage, width: usize, height: usize) -> Vec<u8> {
    let image_width = image.width() as usize;
    let image_height = image.height() as usize;
    let mut pixels = vec![0; width.saturating_mul(height).saturating_mul(4)];
    for y in 0..height {
        let source_y = y * image_height / height.max(1);
        for x in 0..width {
            let source_x = x * image_width / width.max(1);
            let [r, g, b, _] = image.get_pixel(source_x as u32, source_y as u32).0;
            let index = (y * width + x) * 4;
            let alpha = OVERLAY_ALPHA as u16;
            pixels[index] = ((b as u16 * (255 - alpha) + 0x20 * alpha) / 255) as u8;
            pixels[index + 1] = ((g as u16 * (255 - alpha) + 0x20 * alpha) / 255) as u8;
            pixels[index + 2] = ((r as u16 * (255 - alpha) + 0x20 * alpha) / 255) as u8;
            pixels[index + 3] = 255;
        }
    }
    pixels
}

struct OverlayState {
    image_width: u32,
    image_height: u32,
    window_width: i32,
    window_height: i32,
    start: Option<(i32, i32)>,
    current: (i32, i32),
    selection: Option<(u32, u32, u32, u32)>,
    cancelled: bool,
    render: Option<OverlayRender>,
}

pub fn capture_region(output: &Path) -> Result<Capture, PlatformError> {
    let _ = fs::remove_file(output);
    // xcap reports monitor bounds in physical pixels. Keep the overlay in the
    // same coordinate space so the crop maps correctly on high-DPI displays.
    let _ = unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
    let mut cursor = POINT::default();
    unsafe { GetCursorPos(&mut cursor) }.map_err(|error| {
        PlatformError::Output(format!("could not get cursor position: {error}"))
    })?;

    let monitor = Monitor::from_point(cursor.x, cursor.y)
        .map_err(|error| PlatformError::Output(format!("could not find monitor: {error}")))?;
    let monitor_x = monitor
        .x()
        .map_err(|error| PlatformError::Output(format!("could not read monitor x: {error}")))?;
    let monitor_y = monitor
        .y()
        .map_err(|error| PlatformError::Output(format!("could not read monitor y: {error}")))?;
    let window_width = monitor
        .width()
        .map_err(|error| PlatformError::Output(format!("could not read monitor width: {error}")))?
        .min(i32::MAX as u32) as i32;
    let window_height = monitor
        .height()
        .map_err(|error| PlatformError::Output(format!("could not read monitor height: {error}")))?
        .min(i32::MAX as u32) as i32;
    let mut state = OverlayState {
        image_width: window_width.max(1) as u32,
        image_height: window_height.max(1) as u32,
        window_width,
        window_height,
        start: None,
        current: (0, 0),
        selection: None,
        cancelled: false,
        render: None,
    };
    let image = run_overlay(monitor_x, monitor_y, &monitor, &mut state)?;

    if state.cancelled {
        return Ok(Capture::Cancelled);
    }
    let (x, y, width, height) = state
        .selection
        .ok_or_else(|| PlatformError::Output("no capture region was selected".to_owned()))?;
    if width == 0 || height == 0 {
        return Ok(Capture::Cancelled);
    }

    crop_imm(&image, x, y, width, height)
        .to_image()
        .save(output)
        .map_err(|error| PlatformError::Output(format!("could not save PNG: {error}")))?;
    Ok(Capture::Saved)
}

fn run_overlay(
    x: i32,
    y: i32,
    monitor: &Monitor,
    state: &mut OverlayState,
) -> Result<RgbaImage, PlatformError> {
    let instance = unsafe { GetModuleHandleW(None) }
        .map_err(|error| PlatformError::Output(format!("could not get module handle: {error}")))?;
    let class_name = w!("kocr_capture_overlay");
    let cross_cursor = unsafe { LoadCursorW(None, IDC_CROSS) }.unwrap_or_default();
    let class = WNDCLASSW {
        lpfnWndProc: Some(overlay_window_proc),
        hInstance: HINSTANCE(instance.0),
        hCursor: cross_cursor,
        lpszClassName: class_name,
        ..Default::default()
    };
    // A zero return here can also mean that this process registered the class
    // during an earlier capture; CreateWindowExW will still use that class.
    let _ = unsafe { RegisterClassW(&class) };

    let width = state.window_width.max(1) as usize;
    let height = state.window_height.max(1) as usize;
    // Create a transparent frame first. This window can be shown before xcap
    // runs, so the desktop image captured below is never contaminated by the
    // eventual frozen overlay.
    state.render = Some(OverlayRender::new(
        width,
        height,
        vec![0; width.saturating_mul(height).saturating_mul(4)],
    )?);
    let ex_style = WINDOW_EX_STYLE(WS_EX_LAYERED.0 | WS_EX_TOPMOST.0 | WS_EX_TOOLWINDOW.0);
    let hwnd = unsafe {
        CreateWindowExW(
            ex_style,
            class_name,
            w!("kocr capture"),
            WINDOW_STYLE(WS_POPUP.0),
            x,
            y,
            state.window_width,
            state.window_height,
            None,
            None,
            Some(HINSTANCE(instance.0)),
            Some(state as *mut OverlayState as *const _),
        )
    }
    .map_err(|error| PlatformError::Output(format!("could not create capture overlay: {error}")))?;
    refresh_overlay(hwnd, state);
    unsafe {
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        let _ = SetFocus(Some(hwnd));
    }

    let image = match monitor.capture_image() {
        Ok(image) => image,
        Err(error) => {
            unsafe {
                let _ = DestroyWindow(hwnd);
            }
            return Err(PlatformError::Output(format!(
                "could not capture monitor: {error}"
            )));
        }
    };
    if image.width() == 0 || image.height() == 0 {
        unsafe {
            let _ = DestroyWindow(hwnd);
        }
        return Err(PlatformError::Output(
            "monitor capture was empty".to_owned(),
        ));
    }
    state.image_width = image.width();
    state.image_height = image.height();
    let background = frozen_background(&image, width, height);
    if let Some(render) = state.render.as_mut() {
        render.set_background(background);
    }
    refresh_overlay(hwnd, state);
    unsafe {
        let cross_cursor = LoadCursorW(None, IDC_CROSS).unwrap_or_default();
        let _ = SetCursor(Some(cross_cursor));
        let _ = SetCapture(hwnd);
    }

    let mut message = MSG::default();
    loop {
        let result = unsafe { GetMessageW(&mut message, None, 0, 0) };
        if result.0 <= 0 {
            break;
        }
        unsafe {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        if state.selection.is_some() || state.cancelled {
            break;
        }
    }
    unsafe {
        let _ = ReleaseCapture();
        let _ = DestroyWindow(hwnd);
    }
    Ok(image)
}

unsafe extern "system" fn overlay_window_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> windows::Win32::Foundation::LRESULT {
    let state = if message == WM_NCCREATE {
        let create = unsafe { &*(lparam.0 as *const CREATESTRUCTW) };
        unsafe {
            let _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA_INDEX, create.lpCreateParams as isize);
            &mut *(create.lpCreateParams as *mut OverlayState)
        }
    } else {
        let pointer = unsafe { GetWindowLongPtrW(hwnd, GWLP_USERDATA_INDEX) };
        if pointer == 0 {
            return unsafe { DefWindowProcW(hwnd, message, wparam, lparam) };
        }
        unsafe { &mut *(pointer as *mut OverlayState) }
    };

    match message {
        WM_NCHITTEST => windows::Win32::Foundation::LRESULT(1),
        WM_SETCURSOR => {
            let cursor = unsafe { LoadCursorW(None, IDC_CROSS) }.unwrap_or_default();
            unsafe {
                let _ = SetCursor(Some(cursor));
            }
            windows::Win32::Foundation::LRESULT(1)
        }
        WM_LBUTTONDOWN => {
            let point = clamp_point(state, mouse_point(lparam));
            state.start = Some(point);
            state.current = point;
            unsafe {
                let _ = SetCapture(hwnd);
            }
            refresh_overlay(hwnd, state);
            windows::Win32::Foundation::LRESULT(0)
        }
        WM_MOUSEMOVE => {
            let cursor = unsafe { LoadCursorW(None, IDC_CROSS) }.unwrap_or_default();
            unsafe {
                let _ = SetCursor(Some(cursor));
            }
            if state.start.is_some() {
                let current = clamp_point(state, mouse_point(lparam));
                if current != state.current {
                    state.current = current;
                    refresh_overlay(hwnd, state);
                }
            }
            windows::Win32::Foundation::LRESULT(0)
        }
        WM_LBUTTONUP => {
            if let Some(start) = state.start.take() {
                let end = clamp_point(state, mouse_point(lparam));
                state.selection = Some(selection_to_image(state, start, end));
                unsafe {
                    let _ = ReleaseCapture();
                    let _ = DestroyWindow(hwnd);
                }
            }
            windows::Win32::Foundation::LRESULT(0)
        }
        WM_RBUTTONDOWN | WM_KEYDOWN if message == WM_RBUTTONDOWN || wparam.0 == 0x1B => {
            state.cancelled = true;
            unsafe {
                let _ = ReleaseCapture();
                let _ = DestroyWindow(hwnd);
            }
            windows::Win32::Foundation::LRESULT(0)
        }
        WM_ERASEBKGND => windows::Win32::Foundation::LRESULT(1),
        WM_PAINT => {
            paint_overlay(hwnd, state);
            windows::Win32::Foundation::LRESULT(0)
        }
        WM_DESTROY => windows::Win32::Foundation::LRESULT(0),
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

fn mouse_point(lparam: LPARAM) -> (i32, i32) {
    (
        ((lparam.0 as u32 & 0xffff) as i16) as i32,
        (((lparam.0 as u32 >> 16) & 0xffff) as i16) as i32,
    )
}

fn clamp_point(state: &OverlayState, (x, y): (i32, i32)) -> (i32, i32) {
    (
        x.clamp(0, state.window_width.saturating_sub(1)),
        y.clamp(0, state.window_height.saturating_sub(1)),
    )
}

fn selection_to_image(
    state: &OverlayState,
    start: (i32, i32),
    end: (i32, i32),
) -> (u32, u32, u32, u32) {
    let left = start.0.min(end.0).max(0) as u64;
    let top = start.1.min(end.1).max(0) as u64;
    let right = start.0.max(end.0).max(0) as u64;
    let bottom = start.1.max(end.1).max(0) as u64;
    let ww = state.window_width.max(1) as u64;
    let wh = state.window_height.max(1) as u64;
    let x = (left * state.image_width as u64 / ww) as u32;
    let y = (top * state.image_height as u64 / wh) as u32;
    let right = (right * state.image_width as u64 / ww).min(state.image_width as u64) as u32;
    let bottom = (bottom * state.image_height as u64 / wh).min(state.image_height as u64) as u32;
    (x, y, right.saturating_sub(x), bottom.saturating_sub(y))
}

fn refresh_overlay(hwnd: HWND, state: &mut OverlayState) {
    let selection = state.start.map(|start| {
        let end = state.current;
        RECT {
            left: start.0.min(end.0),
            top: start.1.min(end.1),
            right: start.0.max(end.0),
            bottom: start.1.max(end.1),
        }
    });
    let Some(render) = state.render.as_mut() else {
        return;
    };
    render.draw(selection);
    let size = SIZE {
        cx: render.width as i32,
        cy: render.height as i32,
    };
    let source = POINT { x: 0, y: 0 };
    let blend = BLENDFUNCTION {
        BlendOp: AC_SRC_OVER as u8,
        BlendFlags: 0,
        SourceConstantAlpha: 255,
        AlphaFormat: AC_SRC_ALPHA as u8,
    };
    unsafe {
        let _ = UpdateLayeredWindow(
            hwnd,
            None,
            None,
            Some(&size),
            Some(render.hdc),
            Some(&source),
            COLORREF(0),
            Some(&blend),
            ULW_ALPHA,
        );
    }
}

fn paint_overlay(hwnd: HWND, state: &mut OverlayState) {
    let mut paint = PAINTSTRUCT::default();
    unsafe {
        let _ = BeginPaint(hwnd, &mut paint);
    }
    refresh_overlay(hwnd, state);
    unsafe {
        let _ = EndPaint(hwnd, &paint);
    }
}

pub fn dependencies() -> &'static [&'static str] {
    &[]
}
