//! Capture thumbnail texture loading.

use eframe::egui;

const THUMBNAIL_MAX: u32 = 320;
const PREVIEW_MAX: u32 = 1024;

pub(crate) fn texture_from_path(
    ctx: &egui::Context,
    path: &std::path::Path,
    id: i64,
) -> Result<egui::TextureHandle, String> {
    texture_from_path_with_max(ctx, path, format!("capture-{id}"), THUMBNAIL_MAX)
}

pub(crate) fn preview_from_path(
    ctx: &egui::Context,
    path: &std::path::Path,
    id: i64,
) -> Result<egui::TextureHandle, String> {
    texture_from_path_with_max(ctx, path, format!("preview-{id}"), PREVIEW_MAX)
}

fn texture_from_path_with_max(
    ctx: &egui::Context,
    path: &std::path::Path,
    name: String,
    max_size: u32,
) -> Result<egui::TextureHandle, String> {
    let png = std::fs::read(path).map_err(|error| error.to_string())?;
    let image = image::load_from_memory(&png)
        .map_err(|error| error.to_string())?
        .to_rgba8();
    let (width, height) = image.dimensions();
    let scale = (max_size as f64 / width as f64)
        .min(max_size as f64 / height as f64)
        .min(1.0);
    let display = if scale < 1.0 {
        image::imageops::resize(
            &image,
            ((width as f64 * scale).round() as u32).max(1),
            ((height as f64 * scale).round() as u32).max(1),
            image::imageops::FilterType::Triangle,
        )
    } else {
        image
    };
    let (width, height) = display.dimensions();
    let color = egui::ColorImage::from_rgba_unmultiplied(
        [width as usize, height as usize],
        display.as_raw(),
    );
    Ok(ctx.load_texture(name, color, egui::TextureOptions::LINEAR))
}
