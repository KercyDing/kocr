#![cfg_attr(windows, windows_subsystem = "windows")]
//! Desktop app for capture, OCR models, shortcuts, and the system tray.

#[macro_use]
extern crate rust_i18n;

i18n!("locales", fallback = "en");

mod app;
mod history;
mod models;
mod preferences;
mod shortcuts;
mod texture;
mod tray;
mod ui;

use eframe::egui;

use app::KocrApp;
use preferences::Preferences;

fn load_window_icon() -> egui::IconData {
    let image = image::load_from_memory(include_bytes!("../assets/icon.png"))
        .expect("embedded icon is valid")
        .into_rgba8();
    let (width, height) = image.dimensions();
    egui::IconData {
        rgba: image.into_raw(),
        width,
        height,
    }
}

#[cfg(target_os = "linux")]
fn configure_tray_window(options: &mut eframe::NativeOptions) {
    use winit::platform::x11::EventLoopBuilderExtX11;

    let has_x11 = std::env::var_os("DISPLAY").is_some_and(|display| !display.is_empty());
    if !has_x11 {
        return;
    }
    options.event_loop_builder = Some(Box::new(|builder| {
        builder.with_x11();
    }));
}

#[cfg(not(target_os = "linux"))]
fn configure_tray_window(_options: &mut eframe::NativeOptions) {}

fn main() -> eframe::Result {
    let preferences = Preferences::load();
    rust_i18n::set_locale(&preferences.locale);
    let persist_window = preferences.remember_window_state;
    let mut options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([560.0, 480.0])
            .with_min_inner_size([520.0, 440.0])
            .with_icon(load_window_icon()),
        renderer: eframe::Renderer::Glow,
        persist_window,
        ..Default::default()
    };
    configure_tray_window(&mut options);
    eframe::run_native(
        "KOCR",
        options,
        Box::new(move |cc| {
            ui::setup_fonts(&cc.egui_ctx);
            ui::apply_ui_style(&cc.egui_ctx, preferences.font_size);
            cc.egui_ctx
                .set_theme(ui::theme_preference(&preferences.theme));
            Ok(Box::new(KocrApp::new(cc.egui_ctx.clone(), preferences)))
        }),
    )
}
