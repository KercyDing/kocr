//! Capture thumbnail texture loading.

use eframe::egui;

pub(crate) fn texture_from_path(
    ctx: &egui::Context,
    path: &std::path::Path,
    id: i64,
) -> Result<egui::TextureHandle, String> {
    let png = std::fs::read(path).map_err(|error| error.to_string())?;
    texture_from_png(ctx, &png, format!("capture-{id}"))
}

pub(crate) fn texture_from_png(
    ctx: &egui::Context,
    png: &[u8],
    name: String,
) -> Result<egui::TextureHandle, String> {
    let image = image::load_from_memory(png)
        .map_err(|error| error.to_string())?
        .to_rgba8();
    let (width, height) = image.dimensions();
    const DISPLAY_TEXTURE_MAX: u32 = 320;
    let scale = (DISPLAY_TEXTURE_MAX as f64 / width as f64)
        .min(DISPLAY_TEXTURE_MAX as f64 / height as f64)
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
